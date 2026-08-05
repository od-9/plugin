/*
	Changelog

	v 2.2
		* New admin command: sm_gasmenu <steam64ID> "config name".
		* Vulnerability patch:
			a) don't allow users to save configs with more gas than the map allows.
			b) logs event where users try to save configs with more gas items than the map allows. 
			c) logs event where survival round started with more gas items than the map allows. 
				(logged events are saved on GM servers in a few places).
			d) Stricter Binary search in query to avoid double, triple, etc.. loading configs
				with same names but different capitalizations (laps, Laps, lapS...).
		* Logging of personal configs usage (load, create, delete, manual_load) with a seperate DB table.

	v 2.1
		* Default gas spawns are added automatically on map load so admins can easily add special ammo when creating new configs.
		* Fixed a bug where the DefaultGasHandle() function would get called indefinitely when the server's empty.


	v 2.0
		personal config support via database
	
	v 1.0
		Initial release

 */

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <adminmenu>
#include <weapons>
#include <regex>
//#include <survivalrecorder>

#pragma semicolon 1
#pragma newdecls required

#define DEBUG		0
#define DEBUGLOG 	0
#define PLUGIN_VERSION "2.2"

#define CFG_PATH	"data/gas_item_counts.cfg"

#define L4D_TEAM_SPECTATE 1
#define L4D_TEAM_SURVIVORS 2
#define L4D_TEAM_INFECTED 3

#define MODELID_NICK 194
#define MODELID_ROCHELLE 195
#define MODELID_COACH 196
#define MODELID_ELLIS 197
#define MODELID_BILL 90
#define MODELID_ZOEY 91
#define MODELID_FRANCIS 92
#define MODELID_LOUIS 93

#define HIGHLIGHT_TIMER	6.0
#define COLOR_RED			999
#define COLOR_BLUE		200000000
#define COLOR_YELLOW		1238947
#define COLOR_WHITE		9999999

#define MAX_QUERY_LENGTH		4096

#define KEY_USERID				"userid"
#define KEY_PHR					"previous_query_has_results"
#define KEY_OWNERNAMEESCAPED	"owner_name_escaped"
#define KEY_OWNERSTEAM64ID		"owner_steam64ID"
#define KEY_LOADERSTEAM64		"steam64ID_user_who_loaded_config"
#define KEY_CONFIGID			"config_UniqueID"
#define KEY_CONFIGNAMEESCAPED	"config_name_escaped"
#define KEY_MAP					"map"
#define KEY_GAS					"gas"
#define KEY_PROPANE				"propane"
#define KEY_FIREWORKS			"fireworks"
#define KEY_SPECIALAMMO			"specialAmmo"

/*
 * TODO:
 * * Fix bug where it puts back the players gun if they're standing next to the gun spawn when loading the gas
 
 * * New syntax: update functions to methodmaps, e.g. ClearTrie(g_hDeletedEnts) -> g_hDeletedEnts.Clear()
 */

public Plugin myinfo =
{
	name = "Gas Configs",
	author = "khan, edits by dustin",
	description = "Save and load gas configs",
	version = PLUGIN_VERSION
};


#define IS_VALID_CLIENT(%1)     (%1 > 0 && %1 <= MaxClients)
#define IS_SURVIVOR(%1)         (GetClientTeam(%1) == 2)
#define IS_VALID_INGAME(%1)     (IS_VALID_CLIENT(%1) && IsClientInGame(%1))
#define IS_VALID_SURVIVOR(%1)   (IS_VALID_INGAME(%1) && IS_SURVIVOR(%1))
#define IS_SURVIVOR_ALIVE(%1)   (IS_VALID_SURVIVOR(%1) && IsPlayerAlive(%1))

#define WEAPON_NOT_CARRIED				0       // Weapon is not with survivor
#define WEAPON_IS_CARRIED_BY_PLAYER		1       // Survivor is carrying weapon
#define WEAPON_IS_ACTIVE					2   	// Survivor has weapon equipped

#define ACTION_CREATE			"create"
#define ACTION_LOAD				"load"
#define ACTION_MANUlLOAD		"manual_load"
#define ACTION_DELETE			"delete"

static const char WeaponSpawnNames[WeaponId][] =
{
	"weapon_none_spawn", "weapon_pistol_spawn", "weapon_smg_spawn",                                            // 0
	"weapon_pumpshotgun_spawn", "weapon_autoshotgun_spawn", "weapon_rifle_spawn",                              // 3
	"weapon_hunting_rifle_spawn", "weapon_smg_silenced_spawn", "weapon_shotgun_chrome_spawn",                  // 6
	"weapon_rifle_desert_spawn", "weapon_sniper_military_spawn", "weapon_shotgun_spas_spawn",                  // 9
	"weapon_first_aid_kit_spawn", "weapon_molotov_spawn", "weapon_pipe_bomb_spawn",                            // 12
	"weapon_pain_pills_spawn", "prop_physics", "prop_physics",                             					   // 15
	"prop_physics", "", "weapon_chainsaw_spawn",                                 			   // 18 weapon_melee_spawn
	"weapon_grenade_launcher_spawn", "weapon_ammo_pack_spawn", "weapon_adrenaline_spawn",                      // 21
	"weapon_defibrillator_spawn", "weapon_vomitjar_spawn", "weapon_rifle_ak47_spawn",                          // 24
	"", "", "prop_physics",                           			   // 27
	"weapon_upgradepack_incendiary_spawn", "weapon_upgradepack_explosive_spawn", "weapon_pistol_magnum_spawn", // 30
	"weapon_smg_mp5_spawn", "weapon_rifle_sg552_spawn", "weapon_sniper_awp_spawn",                             // 33
	"weapon_sniper_scout_spawn", "weapon_rifle_m60_spawn", "",                           // 36
	"", "", "",                       // 39
	"", "", "",                       // 42
	"", "", "",                                                   // 45
	"", "", "",                                                              // 48
	"", "", "",                                                              // 51
	"weapon_ammo_spawn", ""        
};

static const char FireworkModel[] = "models/props_junk/explosive_box001.mdl";
static const char PropaneModel[] = "models/props_junk/propanecanister001a.mdl";

char g_sMapName[128];
char g_sDirPath[PLATFORM_MAX_PATH];
char g_sConfigFilePath[PLATFORM_MAX_PATH];

int g_iMaxSetups;

float g_fHighlightTime;

Handle g_hSetupLimit = INVALID_HANDLE;
Handle g_hLegitCan = INVALID_HANDLE;
Handle g_hAdminMenu = INVALID_HANDLE;
bool g_bAdminMenu[MAXPLAYERS];

int g_iGasCount;
int g_iGasCanCount, iPropaneCount, iFireworkCount, iSpecialAmmoCount;

bool g_bListen[MAXPLAYERS];
int g_iListenStart[MAXPLAYERS];

char g_sDefaultConfig[128];
char g_sHostName[56];

bool g_bRoundStart;
bool g_bLegitCans;
bool g_bHighlightCansToggled;

int g_iOwnerEntity;
int g_iRoundStartLoop;

Handle g_hDeletedEnts = INVALID_HANDLE;

// Database related variables
Database g_hDatabase;

static const char g_sDBEntry[] = "gasconfigs"; // DB entry to use to connect to DB
static const char g_sDBTable[] = "gasconfigs_v2"; // DB table main configs
static const char g_sDBTableLog[] = "gasconfigs_v2_logs"; // DB table logs
bool g_bPersonalConfig;
bool g_PersonalQueryBeingLogged;

Regex g_regex;

ConVar g_cvUseDBEntry;
ConVar g_cvPersonalConfigLimit;

int g_iPersonalConfigCooldownTime;
#define COOLDOWN_ALLOWANCE		3

// Construction site radio is a bunch of gas cans
float g_fConstructionSite_RadioGasSpawn[3] = {-5322.0, -978.0, 16.0};

#define NUM_MODEL_TYPES 5
static const char ModelNames[NUM_MODEL_TYPES][128] = 
{
	"models/props_junk/gascan001a.mdl",
	"models/props_junk/propanecanister001a.mdl",
	"/props_junk/propanecanister001.mdl",
	"models/props_junk/explosive_box001a.mdl",
	"models/props_junk/explosive_box001.mdl"
};
static const char ClassNames[NUM_MODEL_TYPES][128] =
{
	"weapon_gascan",
	"weapon_propanetank",
	"weapon_propanetank",
	"weapon_fireworkcrate",
	"weapon_fireworkcrate"
};

#define NUM_CANS_TYPES 7
static const char UniqueClassNames[NUM_CANS_TYPES][128] = 
{
	"weapon_gascan",
	"weapon_propanetank",
	"weapon_fireworkcrate",
	"upgrade_ammo_incendiary",
	"upgrade_ammo_explosive",
	"weapon_upgradepack_incendiary_spawn",
	"weapon_upgradepack_explosive_spawn"
};

bool g_bMovingCans;

enum struct CanRules
{
  int gas;
  int propane;
  int fireworks;
  int specialAmmo;
}

StringMap g_MapRules;
StringMap g_smQueryValues;

public void OnPluginStart()
{
	// Commands
	RegConsoleCmd("sm_gasmenu", Command_GasMenu, "Loads the gas menu");
	RegConsoleCmd("sm_gashere", Command_MoveGasToClient, "Moves all the gascans to the player");
	
	// Add listeners for setting config names
	AddCommandListener(Command_Say, "say");
	AddCommandListener(Command_Say, "say_team");
	
	// Hook Events
	HookEvent("round_start", Event_RoundStart, EventHookMode_Pre);
	HookEvent("round_end", Event_RoundEnd, EventHookMode_Pre);
	HookEvent("survival_round_start", Event_SurvivalStart, EventHookMode_Pre);
	
	// Convar gas setup limit
	g_hSetupLimit = CreateConVar("l4d2_gasmenu_limit", "20", "Max number of gas setups to allow per map", _, true, 0.0, true, 99.0);
	g_hLegitCan = CreateConVar("l4d2_gasmenu_legitcan", "1", "Whether or not to spawn cans that have correct movement properties", _, true, 0.0, true, 1.0);
	g_cvPersonalConfigLimit = CreateConVar("l4d2_gasmenu_personal_limit", "12", "Max amount of personal configs to allow per map. -1 for infinite.");
	g_cvUseDBEntry = CreateConVar("l4d2_gasmenu_EnablePersonalConfigs", "1", "Enable 'personal configs' feature. Requires 'gasconfigs' database entry to work.",  _, true, 0.0, true, 1.0);
	
	HookConVarChange(g_hSetupLimit, OnSetupLimitChange);
	HookConVarChange(g_hLegitCan, OnLegitCanChange);
	
	g_iMaxSetups = GetConVarInt(g_hSetupLimit);
	g_bLegitCans = GetConVarBool(g_hLegitCan);
	
	g_hDeletedEnts = CreateTrie(); // Would be better if this was a HashSet type list since I don't actually care about the value but whatever..
	g_MapRules = new StringMap();
	g_smQueryValues = new StringMap();

	Initialize();
	InitializeConfigFile();
	
	L4D2Weapons_Init();	// this needs to be called on plugin load when using weapons.inc
	
	g_regex = CompileRegex("[^[:ascii:]]");
	g_iPersonalConfigCooldownTime = GetTime();
}

public void OnConfigsExecuted()
{
	Initialize();
}

void Initialize()
{
	for (int i = 0; i < MAXPLAYERS; i++)
	{
		g_bListen[i] = false;
	}
	g_bRoundStart = false;
	g_bMovingCans = false;
	
	SetListFile();
	
	// Reset the g_iOwnerEntity when the plugin loads. Will happen on map switch which is when this needs to be cleared out...
	g_iOwnerEntity = -1;
	
	// Grab original host name since some servers change hostname as round progresses (e.g. [GM] New York 2 | 13m (9.46 SI/min)[full])
	RequestFrame(GrabHostName);

	#if DEBUGLOG
	LogMessage("GasConfig: Map Switched or plugin loaded");
	#endif
	
	if (g_hDatabase == null && g_cvUseDBEntry.IntValue)
	{
		Database.Connect(OnSQLConnect, g_sDBEntry);
	}
}

void InitializeConfigFile()
{
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), CFG_PATH);

	if(!FileExists(path))
	{
		SetFailState("Missing required config file: \"%s\"", CFG_PATH);
	}

	KeyValues kv = new KeyValues("Rules");
	if (kv.ImportFromFile(path) && kv.GotoFirstSubKey())
	{
		do
		{
			char mapName[32];
			GetCurrentMap(mapName, sizeof(mapName));
			kv.GetSectionName(mapName, sizeof(mapName));

			CanRules rules;
			rules.gas = kv.GetNum("gas");
			rules.propane = kv.GetNum("propane");
			rules.fireworks= kv.GetNum("fireworks");
			rules.specialAmmo = kv.GetNum("special_ammo");
			g_MapRules.SetArray(mapName, rules, 4);
		}
		while (kv.GotoNextKey());		 
	}
	else
	{
		SetFailState("Unable to import file or go to first sub key in config file: \"%s\"", CFG_PATH);
	}

	delete kv;
}


public Action Command_MoveGasToClient(int client, int args)
{
	if (!IS_VALID_SURVIVOR(client))
	{
		PrintToChat(client, "You must be on the survivor team to use this command.");
		return Plugin_Handled;
	}
	else if (g_bRoundStart)
	{
		PrintToChat(client, "You cannot use this command while the round is active.");
		return Plugin_Handled;
	}
	else if (IsMapForbidden())
	{
		PrintToChat(client, "Command not available on this map.");
		return Plugin_Handled;
	}
	
	MoveCansToClient(client);
	
	return Plugin_Handled;
}

public Action Command_GasMenu(int client, int args)
{
	if (args < 1)
	{
		g_bAdminMenu[client] = false;
		ShowGasConfigMenu(client);
		return Plugin_Handled;
	}
	else if (args != 2)
	{
		PrintToChat(client, "[SM] Usage: !gasmenu, !gasmenu <steam64ID> \"<config name>\"");
		return Plugin_Handled;
	}
	
	if (g_cvUseDBEntry.IntValue == 0)
	{
		PrintToChat(client, "[SM] DB error, manual config loadout not available. Contact admin.");
	}
	// manually loading someone's personal config
	else
	{
		char sSteamID[24], sConfigName[40];
		GetCmdArg(1, sSteamID, sizeof(sSteamID));
		GetCmdArg(2, sConfigName, sizeof(sConfigName));
		precheck_personalConfig_ManualLoad(client, sSteamID, sConfigName);
	}
	return Plugin_Handled;
}

void precheck_personalConfig_ManualLoad(int client, const char[] sSteamID_Owner, const char[] sConfigName)
{
	if (!IsClientRootAdmin(client))
	{
		PrintToChat(client, "[SM] Admin command only.");
		return;
	}

	if (!IsStringNumeric(sSteamID_Owner))
	{
		PrintToChat(client, "[SM] invalid steam64ID.");
		return;
	}

	if (g_PersonalQueryBeingLogged)
	{
		PrintToChat(client, "[SM] Another personal config is being processed. Wait a sec.");
		return;
	}

	if (g_bMovingCans)
	{
		PrintToChat(client, "\x04Cans are currently being moved. Wait a sec.");
		return;
	}

	PrintToChatAll("\x01[SM] Admin manually loaded config \x04%s\x01\nSteam64ID associated with config: \x03%s\x01", sConfigName, sSteamID_Owner);

	g_PersonalQueryBeingLogged = true;

	char sMap[32];
	GetCurrentMap(sMap, sizeof(sMap));

	char sSteamID_Loader[24];
	if (GetClientAuthId(client, AuthId_SteamID64, sSteamID_Loader, sizeof(sSteamID_Loader)) == false)
	{
		strcopy(sSteamID_Loader, sizeof(sSteamID_Loader), "steam64ID_not_available");
	}

	int size = 2 * strlen(sConfigName) + 1;
	char[] sEscapedConfigName = new char[size];
	g_hDatabase.Escape(sConfigName, sEscapedConfigName, size);

	char sQuery[MAX_QUERY_LENGTH];
	Format(sQuery, sizeof(sQuery), "SELECT * FROM `%s` WHERE BINARY config_name = '%s' AND map = '%s' AND owner = '%s';", g_sDBTable, sEscapedConfigName, sMap, sSteamID_Owner);

	g_hDatabase.Query(TQuery_LoadPersonalGasConfig, sQuery, GetClientUserId(client));

	// Log personal gas config usage to seperate log table
	g_smQueryValues.Clear();
	g_smQueryValues.SetValue(KEY_USERID, GetClientUserId(client));
	g_smQueryValues.SetString(KEY_CONFIGNAMEESCAPED, sEscapedConfigName);
	g_smQueryValues.SetString(KEY_MAP, sMap);
	g_smQueryValues.SetString(KEY_LOADERSTEAM64, sSteamID_Loader);
	g_smQueryValues.SetString(KEY_OWNERSTEAM64ID, sSteamID_Owner);
	/*
	Need to retrieve: owner_name, owner_steam64ID, config_UniqueID, gas, propane, fireworks, specialAmmo 
		before logging a loadout into the DB again
	Order by id desc to get latest config incase users are making configs with same name over and over 
		(e.g. only want to get the latest version of 'laps'), when they originally created their config (ACTION_CREATE)
	*/
	Format(sQuery, sizeof(sQuery), "SELECT owner_name, config_UniqueID, gas, propane, fireworks, specialAmmo FROM `%s` WHERE BINARY config_name = '%s' AND map = '%s' AND owner_steam64ID = '%s' AND action = '%s' AND is_config_active = '1' ORDER BY id DESC;", g_sDBTableLog, sEscapedConfigName, sMap, sSteamID_Owner, ACTION_CREATE);
	g_hDatabase.Query(DBQuery_RetrieveMetaInfo_load, sQuery);

	// Can't execute this right after DB query. Slight delay
	DataPack pack = new DataPack();
	pack.WriteString(ACTION_MANUlLOAD);
	pack.WriteCell(GetClientUserId(client));
	CreateTimer(1.0, Timer_FinishLoggingStats, pack);
}

public void DBQuery_RetrieveMetaInfo_load(Database db, DBResultSet results, const char[] error, DataPack pack)
{
	if (results == null)
	{
		LogError("DBQuery_RetrieveMetaInfo_load() error with query: %s", error);
		g_smQueryValues.SetValue(KEY_PHR, 0);
		return;
	}

	int i;
	bool bFirstIteration = true;
	while (results.FetchRow())
	{
		if (bFirstIteration)
		{
			bFirstIteration = false;
			char sOwnerName[64], sConfigID[64];
			// SELECT owner_name, config_UniqueID, gas, propane, fireworks, specialAmmo
			results.FetchString(0, sOwnerName, sizeof(sOwnerName));
			results.FetchString(1, sConfigID, sizeof(sConfigID));

			int size = 2 * strlen(sOwnerName) + 1;
			char[] sEscapedOwnerName = new char[size];
			g_hDatabase.Escape(sOwnerName, sEscapedOwnerName, size);

			int gas = results.FetchInt(2);
			int propane = results.FetchInt(3);
			int fireworks = results.FetchInt(4);
			int specialAmmo = results.FetchInt(5);

			g_smQueryValues.SetString(KEY_OWNERNAMEESCAPED, sEscapedOwnerName);
			g_smQueryValues.SetString(KEY_CONFIGID, sConfigID);
			g_smQueryValues.SetValue(KEY_GAS, gas);
			g_smQueryValues.SetValue(KEY_PROPANE, propane);
			g_smQueryValues.SetValue(KEY_FIREWORKS, fireworks);
			g_smQueryValues.SetValue(KEY_SPECIALAMMO, specialAmmo);
			i++;
		}
		else
		{
			break;
		}
	}
	
	// user tried to manually load an invalid config name which returned no results
	if (i == 0)
	{
		g_smQueryValues.SetValue(KEY_PHR, 0);
	}
	else
	{
		g_smQueryValues.SetValue(KEY_PHR, 1);
	}
}

public void OnSetupLimitChange(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_iMaxSetups = GetConVarInt(g_hSetupLimit);
}

public void OnLegitCanChange(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_bLegitCans = GetConVarBool(g_hLegitCan);
}

//=================================
// Move gas cans to player
//=================================

void MoveCansToClient(int client)
{
	if (g_bMovingCans)
	{
		PrintToChat(client, "\x04Cans are currently being moved. Wait a sec.");
		return;
	}
	g_bMovingCans = true;
	
	Handle hDataPack;
	
	CreateDataTimer(0.1, Timer_MoveGas, hDataPack, TIMER_REPEAT);
	FindAllGas(hDataPack, client);
	ResetPack(hDataPack);
}

void FindAllGas(Handle hDataPack, int client)
{
	int entity = -1;
	while ((entity = FindEntityByClassname(entity, "prop_physics")) != -1)
	{
		if (IsEntityConstructionSiteRadio(entity)) continue;
		
		char sModel[PLATFORM_MAX_PATH];
		GetEntPropString(entity, Prop_Data, "m_ModelName", sModel, sizeof(sModel));
		
		if (StrContains(sModel, "gascan") != -1 || StrContains(sModel, FireworkModel) != -1)
		{
			WritePackCell(hDataPack, client);
			WritePackCell(hDataPack, entity);
		}
	}
	
	entity = -1;
	while ((entity = FindEntityByClassname(entity, "weapon_gascan")) != -1)
	{
		if (IsEntityConstructionSiteRadio(entity)) continue;
		
		if (IsValidEntity(entity))
		{
			WritePackCell(hDataPack, client);
			WritePackCell(hDataPack, entity);
		}
	}
}

public Action Timer_MoveGas(Handle hTimer, Handle hDataPack)
{
	if (!IsPackReadable(hDataPack, 16))
	{
		KillTimer(hTimer);
		g_bMovingCans = false;
		return Plugin_Handled;
	}
	
	int client = ReadPackCell(hDataPack);
	int iEnt = ReadPackCell(hDataPack);
	
	float vPos[3];
	GetClientEyePosition(client, vPos);
	
	if (IsValidEntity(iEnt))
	{
		float vVel[3] = { 0.0, 0.0, 0.0};
		TeleportEntity(iEnt, vPos, NULL_VECTOR, vVel);	// Overwriting velocity b/c using NULL_VECTOR for the velocity causes gas cans to float in the air for some reason..
	}
	
	return Plugin_Continue;
}


//=================================
// Listen commands
//=================================
public Action Command_Say(int client, const char[] command, int argc)
{
	if (g_bListen[client])
	{
		g_bListen[client] = false;
		if ((GetTime() - g_iListenStart[client]) >=10)
		{
			return Plugin_Continue;
		}
		
		char text[128];
		int startidx = 0;
		char dest[128];
		if (GetCmdArgString(text, sizeof(text)) < 1)
		{
			return Plugin_Continue;
		}
		if (text[strlen(text)-1] == '"')
		{
			text[strlen(text)-1] = '\0';
			startidx = 1;
		}
		Format(dest, sizeof(dest), text[startidx]);
		
		
		if (g_bPersonalConfig)
		{
			g_bPersonalConfig = false;
			SaveGasConfigToDB(client, dest);
		}
		else
			SaveGasSetupHandle(client, dest);
		
		return Plugin_Handled;
	}
	
	return Plugin_Continue;
}

//=================================
// Helper Methods
//=================================

public void CreateConfigDir()
{
	char path[PLATFORM_MAX_PATH] = "addons/sourcemod/data/GasConfigs";
	
	if (!DirExists(path))
	{
		CreateDirectory(path, 3);
	}
	
	StrCat(path, sizeof(path), "/");
	StrCat(path, sizeof(path), g_sMapName);
	if (!DirExists(path))
	{
		CreateDirectory(path, 3);
	}
	g_sDirPath = path;
}


public void SetKVPath(const char[] fileName, char sCfgPath[PLATFORM_MAX_PATH])
{
	BuildPath(Path_SM, sCfgPath, sizeof(sCfgPath), "data/GasConfigs/%s/%s.cfg", g_sMapName, fileName);
}

public void SetListFile()
{
	// Create the GasConfigs directory if necessary
	char path[PLATFORM_MAX_PATH] = "addons/sourcemod/data/GasConfigs";	
	if (!DirExists(path))
	{
		CreateDirectory(path, 3);
	}
	
	BuildPath(Path_SM, g_sConfigFilePath, sizeof(g_sConfigFilePath), "data/GasConfigs/CfgList.cfg");
}

public void AddToCurrentlyBeingDeletedList(int iEnt)
{
	char sEnt[64];
	
	IntToString(iEnt, sEnt, sizeof(sEnt));
	int val;
	if (!GetTrieValue(g_hDeletedEnts, sEnt, val))
	{
		SetTrieValue(g_hDeletedEnts, sEnt, 1);
	}
}

public void RemoveItem(WeaponId wID)
{
	int iEnt;
	// Find and kill any matching entities.
	while ((iEnt = FindEntityByClassname(iEnt, WeaponNames[wID])) != -1) 
	{
		if (!IsValidEdict(iEnt) || !IsValidEntity(iEnt)) {
			continue;
		}
		
		if (IsEntityConstructionSiteRadio(iEnt)) continue;
		
		AcceptEntityInput(iEnt, "kill");
		AddToCurrentlyBeingDeletedList(iEnt);
	}
	
	// Kill the spawns for the weapon as well
	if (StrEqual(WeaponSpawnNames[wID], "prop_physics", false)) 
	{
		// Gas, propane, and fireworks are all prop_physics. Need to verify that we're killing the correct entity by checking the model. Properly could just kill all prop_physics if we don't care about oxygen tanks...
		KillItemByModel(wID);
	}
	else
	{
		// Look up all spawns for special ammo and kill them.
		KillItemBySpawn(wID);
	} 
}

public void KillItemByModel(WeaponId wID)
{
	int iEnt;
	char sEntModel[128];
	while ((iEnt = FindEntityByClassname(iEnt, WeaponSpawnNames[wID])) != -1) 
	{
		if (!IsValidEdict(iEnt) || !IsValidEntity(iEnt)) {
			continue;
		}
		
		if (IsEntityConstructionSiteRadio(iEnt)) continue;
		
		GetEntPropString(iEnt, Prop_Data, "m_ModelName", sEntModel, sizeof(sEntModel)); 
		if (StrContains(sEntModel, WeaponModels[wID], false) != -1) 
		{
			if (view_as<bool>(GetEntProp(iEnt, Prop_Send, "m_isCarryable", 1))) 
			{
				AcceptEntityInput(iEnt, "kill");
				AddToCurrentlyBeingDeletedList(iEnt);
			}
		}
		else if (wID == view_as<WeaponId>(WEPID_FIREWORKS_BOX) && StrEqual(sEntModel, FireworkModel, false)) // fireworks use a different model then what the weapons.inc lists... at least in concert survival.
		{
			if (view_as<bool>(GetEntProp(iEnt, Prop_Send, "m_isCarryable", 1)))
			{
				AcceptEntityInput(iEnt, "kill");
				AddToCurrentlyBeingDeletedList(iEnt);
			}			
		}
		else if (wID == view_as<WeaponId>(WEPID_PROPANE_TANK) && StrEqual(sEntModel, PropaneModel, false))
		{
			if (view_as<bool>(GetEntProp(iEnt, Prop_Send, "m_isCarryable", 1)))
			{
				AcceptEntityInput(iEnt, "kill");
				AddToCurrentlyBeingDeletedList(iEnt);
			}
		}
	}
}

public void KillItemBySpawn(WeaponId wID)
{
	int iEnt;
	while ((iEnt = FindEntityByClassname(iEnt, WeaponSpawnNames[wID])) != -1) 
	{
		if (!IsValidEdict(iEnt) || !IsValidEntity(iEnt)) {
			continue;
		}
		
		if (IsEntityConstructionSiteRadio(iEnt)) continue;
		
		AcceptEntityInput(iEnt, "kill");
		AddToCurrentlyBeingDeletedList(iEnt);
	}
}

public bool IsWeaponEquipped(int weapon)
{
	int state = GetEntProp(weapon, Prop_Data, "m_iState");
	
	if (state == WEAPON_IS_ACTIVE)
	{
		return true;
	}
	
	return false;
}

public void ChangeSpawnType(int client, bool bUseLegitCans)
{
	if (bUseLegitCans)
	{
		SetConVarBool(g_hLegitCan, true);
		PrintToChat(client, "\x04Will place cans with the correct movement settings.");
	}
	else
	{
		SetConVarBool(g_hLegitCan, false);
		PrintToChat(client, "\x04Will use default incorrect movement settings when moving cans.");
	}
	g_bLegitCans = GetConVarBool(g_hLegitCan);
}

public Action Timer_RetakePlayer(Handle timer, any client)
{
	RetakePlayer(client);
}

//
// Bot equivalent of RetakePlayer(). Bots can't spectate and rejoin, so instead we
// throw away the kit/pills the gas-can routine left in a bad state and give the bot
// fresh ones, which attach normally and drop on death like they should.
//
public Action Timer_RefreshBotItems(Handle timer, any userid)
{
	int client = GetClientOfUserId(userid);

	if (client > 0 && IS_SURVIVOR_ALIVE(client) && IsFakeClient(client))
	{
		RefreshItemSlot(client, 3);	// first aid kit / defib
		RefreshItemSlot(client, 4);	// pills / adrenaline
	}

	return Plugin_Continue;
}

void RefreshItemSlot(int client, int slot)
{
	int item = GetPlayerWeaponSlot(client, slot);
	if (item == -1)
	{
		return;
	}

	char sClassname[64];
	if (!GetEdictClassname(item, sClassname, sizeof(sClassname)))
	{
		return;
	}

	RemovePlayerItem(client, item);
	AcceptEntityInput(item, "kill");

	int newItem = CreateEntityByName(sClassname);
	if (newItem == -1)
	{
		return;
	}

	DispatchSpawn(newItem);
	EquipPlayerWeapon(client, newItem);
}

void RetakePlayer(int client)
{
	int model = GetEntProp(client, Prop_Send, "m_nModelIndex");
	char bot[32];
	
	switch (model)
	{
		case MODELID_NICK:
		{
			bot = "Nick";
		}
		case MODELID_ROCHELLE:
		{
			bot = "Rochelle";
		}
		case MODELID_COACH:
		{
			bot = "Coach";
		}
		case MODELID_ELLIS:
		{
			bot = "Ellis";
		}
		case MODELID_BILL:
		{
			bot = "Bill";
		}
		case MODELID_ZOEY:
		{
			bot = "Zoey";
		}
		case MODELID_LOUIS:
		{
			bot = "Louis";
		}
		case MODELID_FRANCIS:
		{
			bot = "Francis";
		}
	}
	
	if (!StrEqual(bot, ""))
	{
		ChangePlayerTeam(client, L4D_TEAM_SPECTATE, "");
		ChangePlayerTeam(client, L4D_TEAM_SURVIVORS, bot);	
	}
}

void ChangePlayerTeam(int client, int team, const char[] player)
{
	if(GetClientTeam(client) == team) return;
	
	// For spectate or infected, simply move the player over
	if(team != L4D_TEAM_SURVIVORS)
	{
		ChangeClientTeam(client, team);
		return;
	}
	
	//for survivors its more tricky...
	char command[] = "sb_takecontrol";
	int flags = GetCommandFlags(command);
	SetCommandFlags(command, flags & ~FCVAR_CHEAT);
	
	char botNames[][128] = { "ellis", "nick", "coach", "rochelle", "zoey", "louis", "bill", "francis" };
	
	int cTeam;
	cTeam = GetClientTeam(client);
	
	char dest[128];
	int i = 0;
	while(cTeam != L4D_TEAM_SURVIVORS && i < 8) // while player isn't on survivor, max retry of 8 times just in case...
	{
		// Check if they selected a specific survivor to play as
		if (player[0] != EOS)
		{
			// Loook for specific survivor
			dest = botNames[i];
			if (strlen(player) < strlen(botNames[i]))
			{
				ReplaceString(dest, sizeof(dest), botNames[i][strlen(player)], "");
			}
			
			if (!StrEqual(dest, player, false))
			{
				// Not the bot that they want, continue looking
				i++;
				continue;
			}
		}
		
		// Have player take over the bot
		char sCmd[64];
		Format(sCmd, sizeof(sCmd), "sb_takecontrol %s", botNames[i]);
		FakeClientCommand(client, sCmd);

		cTeam = GetClientTeam(client);
		i++;	//this shouldn't be needed but just in case...
	}
}

bool IsEntityConstructionSiteRadio(int iEntity)
{
	char sMap[32];
	GetCurrentMap(sMap, sizeof(sMap));
	if (!StrEqual(sMap, "c11m3_garage"))
	{
		return false;
	}
	
	float vec[3];
	GetEntPropVector(iEntity, Prop_Send, "m_vecOrigin", vec);
	if ( GetVectorDistance(vec, g_fConstructionSite_RadioGasSpawn) < 50 )
	{
		return true;
	}
	return false;
}

//=================================
// Save methods
//=================================
public void StartListenForSave(int client)
{
	PrintToChat(client, "You have 10 seconds to type the config name in chat.");
	g_bListen[client] = true;
	g_iListenStart[client] = GetTime();		
}

public void SaveGasSetupHandle(int client, char[] name)
{
	GetCurrentMap(g_sMapName, sizeof(g_sMapName));
	
	// Verify that the directory for this map exists
	CreateConfigDir();
	
	if (SaveGasSetup(client, name))
	{
		if (client > 0) PrintToChatAll("\x05New gas config saved [\x04%s\x05]", name);
	}
}



public bool SaveGasSetup(int client, char[] name)
{
	if (!CheckListCount(client, name))
	{
		return false;
	}

	char sCfgPath[PLATFORM_MAX_PATH];
	SetKVPath(name, sCfgPath);

	// Find all the gas and save the setup
	Handle kv = CreateKeyValues("GasConfig");
	FindGas(kv);
	KeyValuesToFile(kv, sCfgPath);
	CloseHandle(kv);
	
	return true;
}

public void FindGas(Handle kv)
{
	g_iGasCount = 0;
	int iEnt;
	
	// Look for any gas cans that have been moved around the map
	for (int i = 0; i < NUM_CANS_TYPES; i++)
	{
		while ((iEnt = FindEntityByClassname(iEnt, UniqueClassNames[i])) != -1) 
		{
			if (!IsValidEdict(iEnt) || !IsValidEntity(iEnt)) {
				continue;
			}
			
			if (IsEntityConstructionSiteRadio(iEnt)) continue;
			
			ProcessGasCan(iEnt, UniqueClassNames[i], kv);
		}
	}
	
	char sEntModel[128];
	// Second loop for prop_physics objects since we need to look at the model name
	while ((iEnt = FindEntityByClassname(iEnt, "prop_physics")) != -1) 
	{
		if (!IsValidEdict(iEnt) || !IsValidEntity(iEnt)) {
			continue;
		}
		
		if (IsEntityConstructionSiteRadio(iEnt)) continue;
		
		GetEntPropString(iEnt, Prop_Data, "m_ModelName", sEntModel, sizeof(sEntModel)); 
		for (int i = 0; i < NUM_MODEL_TYPES; i++)
		{
			if (StrEqual(sEntModel, ModelNames[i], false)) 
			{
				if (view_as<bool>(GetEntProp(iEnt, Prop_Send, "m_isCarryable", 1)))
				{
					ProcessGasCan(iEnt, ClassNames[i], kv);
					continue;
				}	
			}
		}
	}
}


public void ProcessGasCan(int iEnt, const char[] class, Handle kv)
{
	float position[3];
	float angle[3];
	GetEntPropVector(iEnt, Prop_Send, "m_vecOrigin", position);
	GetEntPropVector(iEnt, Prop_Send, "m_angRotation", angle);
	
	// Create unique key
	char key[128] = "explosive";
	char name[128];
	IntToString(g_iGasCount, name, sizeof(name));
	StrCat(key, sizeof(key), name);

	// Add gascan as keyvalue
	KvJumpToKey(kv, key, true);
	KvSetString(kv, "class", class);
	KvSetVector(kv, "position", position);
	KvSetVector(kv, "angle", angle);
	KvRewind(kv);
	
	g_iGasCount++;
}


//===========================
// Load Methods
//===========================

public void LoadGasSetupHandle(char[] fileName, int client)
{	
	GetCurrentMap(g_sMapName, sizeof(g_sMapName));
	
	char sCfgPath[PLATFORM_MAX_PATH];
	SetKVPath(fileName, sCfgPath);
	
	if (!FileExists(sCfgPath)) 
	{
		#if DEBUG
		PrintToChatAll("[LoadGasSetupHandle] File doesn't exist: %s", sCfgPath);
		#endif
		return;
	}
	
	LoadGasConfig(sCfgPath, client);
}

public void LoadGasConfig(const char[] sCfgPath, int client)
{
	Handle kv = CreateKeyValues("GasConfig");
	if (!FileToKeyValues(kv, sCfgPath))
	{
		#if DEBUG
		PrintToChatAll("[LoadGasConfig] Couldn't process file: %s", sCfgPath);
		#endif
		CloseHandle(kv);
		return;
	}
	
	if (!KvGotoFirstSubKey(kv))
	{
		#if DEBUG
		PrintToChatAll("[LoadGasConfig] GotoFirstSubKey failed");
		#endif
		CloseHandle(kv);
		return;
	}
	
	// Reset our tracking of which entities are in the middle of being killed
	ClearTrie(g_hDeletedEnts);
	
	// Always remove existing special ammo and let the plugin re-place them in the "correct" location
	RemoveNonGasSpawns();
	
	// Reset the g_iOwnerEntity property value. Plugin will look it up.
	//g_iOwnerEntity = -1;
	
	// Initialize some stuff
	Handle hGasList = CreateStack(6);
	Handle hPropaneList = CreateStack(6);
	Handle hFireworkList = CreateStack(6);
	
	int numGas = 0;
	int numPropane = 0;
	int numFireworks = 0;
	
	char buffer[255];
	char class[64];
	float position[3];
	float angle[3];
	
	// Look up the setup information from the config file
	do
	{
		KvGetSectionName(kv, buffer, sizeof(buffer));
		KvGetString(kv, "class", class, sizeof(class));
		KvGetVector(kv, "position", position);
		KvGetVector(kv, "angle", angle);
		
		// Track the gas/propane/fireworks in a stack. Need special handling to spawn these out with the correct settings.
		if (StrEqual(class, WeaponNames[view_as<WeaponId>(WEPID_GASCAN)]))
		{
			AddToStack(hGasList, position, angle);
			numGas++;
		}
		else if (StrEqual(class, WeaponNames[view_as<WeaponId>(WEPID_PROPANE_TANK)]))
		{
			AddToStack(hPropaneList, position, angle);
			numPropane++;
		}
		else if (StrEqual(class, WeaponNames[view_as<WeaponId>(WEPID_FIREWORKS_BOX)]))
		{
			AddToStack(hFireworkList, position, angle);
			numFireworks++;
		}
		else
		{
			// Non-gas related items (ie. special ammo) can be spawned out right away
			SpawnItem(class, position, angle);
		}
	
	} while (KvGotoNextKey(kv, false));
	
	CloseHandle(kv);
	
	
	/* 
	 * Spawn gas cans, propane, fireworks into map by giving to player then forcing them to drop the can so that the gas cans move as they're supposed to (e.g. gas cans should move if a boomer explodes next to them)
	 * Note: if this is done within the first few seconds of a round then it will cause the players pills/kit to stick to them when they die and be unusable to others. Forcing the player to quickly spec/rejoin will fix this which is what the plugin does now.
	 */
	
	bool bRetakeSurvivor = false;
	// First find a client to give the gas to if needed
	if (client == -1)
	{
		int playerSurvivor = -1;
		// Client didn't run this command - ie. beginning of round or map transition
		for (int i = 0; i < MAXPLAYERS; i++)
		{
			if (IS_SURVIVOR_ALIVE(i))
			{
				if (IsFakeClient(i))
				{
					// Prefer using a bot survivor for this
					client = i;
					break;
				}
				else if (playerSurvivor == -1)
				{
					playerSurvivor = i;
				}
			}
		}
		
		if (client == -1 && playerSurvivor != -1)
		{
			// This is the start of the round and we're using a player. Need to make sure we force the player to retake control of the bot to avoid stupid issues..
			client = playerSurvivor;
			bRetakeSurvivor = true;
		}
	}
	
	// Determine how to spawn out the gas
	if (client == -1 || !UseLegitCanSetup())
	{
		#if DEBUGLOG
		LogMessage("Spawning gas the old way");
		#endif
		/* Don't have a valid survivor or admin wanted to spawn it the old way. Spawn the gas normally. The movement of the gas will be off but whatever... */
		
		// Remove the existing gas from the map
		RemoveGasSpawns();
		
		// Spawn out the gas to the correct location
		while (!IsStackEmpty(hGasList))
		{
			PopStackAndSpawn(hGasList, view_as<WeaponId>(WEPID_GASCAN));
		}
		while (!IsStackEmpty(hPropaneList))
		{
			PopStackAndSpawn(hPropaneList, view_as<WeaponId>(WEPID_PROPANE_TANK));
		}
		while (!IsStackEmpty(hFireworkList))
		{
			PopStackAndSpawn(hFireworkList, view_as<WeaponId>(WEPID_FIREWORKS_BOX));
		}
	}
	else
	{
		/* Spawn out the gas in a way that will cause it to have the correct movement settings */
		#if DEBUGLOG
		LogMessage("Spawning gas cans with the correct movement settings");
		#endif
		
		/*
		PrintToChatAll("Gas: %i - %i", NumSpawns(WeaponId:WEPID_GASCAN), numGas);
		PrintToChatAll("Propane: %i - %i", NumSpawns(WeaponId:WEPID_PROPANE_TANK), numPropane);
		PrintToChatAll("Fireworks: %i - %i", NumSpawns(WeaponId:WEPID_FIREWORKS_BOX), numFireworks);
		*/
		
		bool bNewCans = false;
		if (NumSpawns(view_as<WeaponId>(WEPID_GASCAN)) != numGas ||
			NumSpawns(view_as<WeaponId>(WEPID_PROPANE_TANK)) != numPropane ||
			NumSpawns(view_as<WeaponId>(WEPID_FIREWORKS_BOX)) != numFireworks)
		{
			// Don't have enough cans on the map to use. Will need to spawn new cans which means special handling in order to spawn cans with the correct movements.
			bNewCans = true;
			#if DEBUGLOG
			LogMessage("  Using new cans because numbers don't match up");
			#endif
		}
		else if (g_iOwnerEntity == -1 && (numPropane > 0 || numFireworks > 0))
		{
			// Don't have a valid g_iOwnerEntity property for this map yet. Need to spawn a propane to find one.
			// *TODO* Shouldn't need to remove the gascans if they're already correct
			bNewCans = true;
			#if DEBUGLOG
			LogMessage("  Using new cans becuase g_iOwnerEntity is -1");
			#endif
		}
		else
		{
			// Already have enough cans on the map. Just move them around instead of spawning new ones.
			bNewCans = false;
		}
		
		if (bNewCans)
		{
			/* Give cans to players and force them to drop it to create a can with the correct movement properties */
			#if DEBUGLOG
			LogMessage("Spawning new gas cans");
			#endif
			
			// Get rid of any existing cans
			RemoveGasSpawns();
			
			int weapon	= GetPlayerWeaponSlot(client, 0); // Need to use primary or secondary. Equiping pills or throwables won't work to create proper gascans...
			if (weapon != -1)
			{
				/* Always use primary for now...
				new secondary = GetPlayerWeaponSlot(client, 1);
				if (secondary != -1 && IsWeaponEquipped(secondary))
				{
					bSecondary = true;
					weapon = secondary;
				} */
			}
			
			int iClip = 0;
			int ammo = 0;
			int iPrimType = -1;
			bool bSpawnedSMG = false;
			
			if (weapon == -1)
			{
				bSpawnedSMG = true;
				// give player an smg temporarily because we need to re-equip a primary or secondary for this to work. When a map loads, the player will only have pistols and re-equiping those causes them to duplicate a bunch - at least the way I was doing things...
				int index = CreateEntityByName("weapon_smg");
				DispatchSpawn(index);
				
				EquipPlayerWeapon(client, index);
				
				weapon = index;
			}
			else
			{
				// Track how much ammo the player had
				iClip = GetEntProp(weapon, Prop_Send, "m_iClip1");
				iPrimType = GetEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType");
				ammo = GetEntProp(client, Prop_Send, "m_iAmmo", _, iPrimType);
			}
			
			for (int i = 0; i < numGas; i++)
			{
				GiveItem(client, "weapon_gascan");
				
				// Force player to drop the gascan. Need to do this after every gas can otherwise the movement settings aren't correct. (ie. dropping gas by giving a new gascan isn't the same as dropping gascan from switching weapons).
				EquipPlayerWeapon(client, weapon);	
			}
			GiveItem(client, "weapon_propanetank");
			
			if (bSpawnedSMG)
			{
				// Kill the SMG now that we're done spawning gas
				AcceptEntityInput(weapon, "kill");
			}
			else
			{
				// Used the players gun, so we don't need to kill it but we do need to correct the ammo for it.
				SetEntProp(weapon, Prop_Send, "m_iClip1", iClip, sizeof(iClip));
				if (iPrimType != -1 && ammo > 0)
				{
					SetEntProp(client, Prop_Send, "m_iAmmo", ammo, _, iPrimType);
				}
			}
			
			// Find the m_hOwnerEntity property of the propane that was spawned. Then kill the entity so that we can spawn in new propane and correctly set that property.
			int iEnt;
			while ((iEnt = FindEntityByClassname(iEnt, WeaponNames[view_as<WeaponId>(WEPID_PROPANE_TANK)])) != -1) 
			{
				if (!IsValidEdict(iEnt) || !IsValidEntity(iEnt)) {
					continue;
				}
				
				if (IsEntityConstructionSiteRadio(iEnt)) continue;
				
				// retrieve the m_hOwnerEntity property...
				g_iOwnerEntity = GetEntProp(iEnt, Prop_Send, "m_hOwnerEntity");
				AcceptEntityInput(iEnt, "kill");	// kill it now that we have the owner entity... 
			}
		}
		
		if (bRetakeSurvivor)
		{
			/* 
			 * Force the player used to create gas cans to join spectators and back to survivor in order to avoid having kit/pills stick to them when they die.
			 * This is only needed if the cans are loaded within the first few seconds of the round restarting. I'm assuming if the client was passed in (i.e. someone is manually loading a setup) that they aren't doing it within the first few seconds and we can skip this.
			 * Waiting a full second because this conflicts with the AutoSetup plugin if this runs before that's finished giving out weapons.
			 */
			CreateTimer(1.0, Timer_RetakePlayer, client);
		}
		else if (bNewCans && IS_SURVIVOR_ALIVE(client) && IsFakeClient(client))
		{
			/*
			 * Same problem, but the carrier was a bot (which is what we prefer above) and
			 * a bot can't be forced through spectate/rejoin. Rebuild its kit and pills
			 * instead - that re-attaches them properly so they drop on death rather than
			 * staying stuck to the body and following the camera around.
			 * Same 1 second delay, for the same AutoSetup reason.
			 */
			CreateTimer(1.0, Timer_RefreshBotItems, GetClientUserId(client));
		}

		// Move the gas cans into place
		FindAndMoveGas(view_as<WeaponId>(WEPID_GASCAN), hGasList);
		
		if (bNewCans)
		{
			// Spawn out all the propane - Propane will not be movable for the player that "spawns" them. The other players can still bump the propane. That's just how things work..
			while (!IsStackEmpty(hPropaneList))
			{
				PopStackAndSpawn(hPropaneList, view_as<WeaponId>(WEPID_PROPANE_TANK));
			}
			
			// Spawn out the fireworks
			while (!IsStackEmpty(hFireworkList))
			{
				PopStackAndSpawn(hFireworkList, view_as<WeaponId>(WEPID_FIREWORKS_BOX));
			}
		}
		else
		{
			#if DEBUGLOG
			LogMessage("Moving around existing cans");
			#endif
			// Find and move the existing propane and fireworks
			FindAndMoveGas(view_as<WeaponId>(WEPID_PROPANE_TANK), hPropaneList);
			FindAndMoveGas(view_as<WeaponId>(WEPID_FIREWORKS_BOX), hFireworkList);
		}
	}
	
}

public bool UseLegitCanSetup()
{
	// The steps for spawning cans with normal movement settings causes weird behavior on
	// rooftop where the kit/pills can stick to one of the survivors when they die. Always
	// have the plugin use the normal cans for this map for now...
	char sMapName[256];
	GetCurrentMap(sMapName, sizeof(sMapName));
	if (StrEqual(sMapName, "c8m5_rooftop"))
	{
		return false;
	}
	
	return g_bLegitCans;
}

/* Find existing spawns and move them to the new location */
public void FindAndMoveGas(WeaponId WEPID, Handle hStack)
{
	int iEnt;
	while ((iEnt = FindEntityByClassname(iEnt, WeaponNames[WEPID])) != -1) 
	{
		if (!IsValidEdict(iEnt) || !IsValidEntity(iEnt)) {
			continue;
		}
		
		if (IsEntityConstructionSiteRadio(iEnt)) continue;
		
		char sEnt[64];
		IntToString(iEnt, sEnt, sizeof(sEnt));
		int val;
		if (GetTrieValue(g_hDeletedEnts, sEnt, val))
		{
			// This is one of the gascan entities that are currently being killed. Killing the entity
			// doesn't occur immediately after running the command to kill it, so we have to check here.
			// Skip this entity.
			continue;
		}
		
		// Move the gas can into position
		PopStackAndMove(hStack, iEnt);
	}
	
	if (!IsStackEmpty(hStack))
	{
		// Try to look up item by model name if the stack isn't empty
		iEnt = -1;
		char sEntModel[128];
		while ((iEnt = FindEntityByClassname(iEnt, WeaponSpawnNames[WEPID])) != -1) 
		{
			if (!IsValidEdict(iEnt) || !IsValidEntity(iEnt)) {
				continue;
			}
			
			if (IsEntityConstructionSiteRadio(iEnt)) continue;
			
			GetEntPropString(iEnt, Prop_Data, "m_ModelName", sEntModel, sizeof(sEntModel));
			if (StrEqual(sEntModel, WeaponModels[WEPID], false)) 
			{
				PopStackAndMove(hStack, iEnt);
			}
			else if (WEPID == view_as<WeaponId>(WEPID_FIREWORKS_BOX) && StrEqual(sEntModel, FireworkModel, false))
			{
				PopStackAndMove(hStack, iEnt);			
			}
			else if (WEPID == view_as<WeaponId>(WEPID_PROPANE_TANK) && StrEqual(sEntModel, PropaneModel, false))
			{
				PopStackAndMove(hStack, iEnt);
			}
		}
	}
}

public int NumSpawns(WeaponId WEPID)
{
	int iEnt;
	int iCount = 0;
	// Look up spawns by classname. Think this only works for gas..
	while ((iEnt = FindEntityByClassname(iEnt, WeaponNames[view_as<WeaponId>(WEPID)])) != -1) 
	{
		if (!IsValidEdict(iEnt) || !IsValidEntity(iEnt)) {
			continue;
		}
		
		if (IsEntityConstructionSiteRadio(iEnt)) continue;
		
		iCount++;
	}
	
	// Try to look for prop_physics spawns by the model name
	iEnt = -1;
	char sEntModel[128];
	while ((iEnt = FindEntityByClassname(iEnt, WeaponSpawnNames[WEPID])) != -1) 
	{
		if (!IsValidEdict(iEnt) || !IsValidEntity(iEnt)) {
			continue;
		}
		
		if (IsEntityConstructionSiteRadio(iEnt)) continue;
		
		GetEntPropString(iEnt, Prop_Data, "m_ModelName", sEntModel, sizeof(sEntModel)); 
		if (StrEqual(sEntModel, WeaponModels[WEPID], false)) 
		{
			if (view_as<bool>(GetEntProp(iEnt, Prop_Send, "m_isCarryable", 1))) // *TODO* why was I doing this check? is this needed?
			{
				iCount++;
			}
		}
		else if (WEPID == view_as<WeaponId>(WEPID_FIREWORKS_BOX) && StrEqual(sEntModel, FireworkModel, false)) // fireworks use a different model then what the weapons.inc lists... at least in concert survival.
		{
			if (view_as<bool>(GetEntProp(iEnt, Prop_Send, "m_isCarryable", 1)))
			{
				iCount++;
			}			
		}
		else if (WEPID == view_as<WeaponId>(WEPID_PROPANE_TANK) && StrEqual(sEntModel, PropaneModel, false))
		{
			if (view_as<bool>(GetEntProp(iEnt, Prop_Send, "m_isCarryable", 1)))
			{
				iCount++;
			}
		}
	}
	
	
	return iCount;
}

public void RemoveNonGasSpawns()
{
	// Remove special ammo spawns
	RemoveItem(view_as<WeaponId>(WEPID_INCENDIARY_AMMO));
	RemoveItem(view_as<WeaponId>(WEPID_FRAG_AMMO));
	
	// Handling to remove already deployed special ammo
	RemoveDeployedSpecialAmmo();
}

public void RemoveDeployedSpecialAmmo()
{
	int iEnt;
	while ((iEnt = FindEntityByClassname(iEnt, "upgrade_ammo_incendiary")) != -1) 
	{
		if (!IsValidEdict(iEnt) || !IsValidEntity(iEnt)) {
			continue;
		}
		AcceptEntityInput(iEnt, "kill");
	}
	
	while ((iEnt = FindEntityByClassname(iEnt, "upgrade_ammo_explosive")) != -1) 
	{
		if (!IsValidEdict(iEnt) || !IsValidEntity(iEnt)) {
			continue;
		}
		AcceptEntityInput(iEnt, "kill");
	}
}

public void RemoveGasSpawns()
{
	RemoveItem(view_as<WeaponId>(WEPID_GASCAN));
	RemoveItem(view_as<WeaponId>(WEPID_PROPANE_TANK));
	RemoveItem(view_as<WeaponId>(WEPID_FIREWORKS_BOX));
}

void AddToStack(Handle hStack, float position[3], float angle[3])
{
	float val[6];
	val[0] = position[0];
	val[1] = position[1];
	val[2] = position[2];
	
	val[3] = angle[0];
	val[4] = angle[1];
	val[5] = angle[2];
	
	PushStackArray(hStack, val, sizeof(val));
}

public void PopStackAndSpawn(Handle hStack, WeaponId wID)
{
	float temp[6];
	float position[3];
	float angle[3];
	
	PopStackArray(hStack, temp, sizeof(temp));
	position[0] = temp[0];
	position[1] = temp[1];
	position[2] = temp[2];
	
	angle[0] = temp[3];
	angle[1] = temp[4];
	angle[2] = temp[5];
	
	SpawnItem(WeaponNames[wID], position, angle);
}

public void PopStackAndMove(Handle hStack, int entity)
{
	if (!IsStackEmpty(hStack))
	{
		
		float val[6];
		PopStackArray(hStack, val, sizeof(val));
		
		float pos[3];
		float ang[3];
		float vel[3] = {0.0, 0.0, 0.0};
		pos[0] = val[0];
		pos[1] = val[1];
		pos[2] = val[2];
		
		ang[0] = val[3];
		ang[1] = val[4];
		ang[2] = val[5];
		
		TeleportEntity(entity, pos, ang, vel);
	}
	else
	{
		#if DEBUG
		PrintToChatAll("[PopStackAndMove] Stack is empty...");
		#endif
	}
}


void GiveItem(int client, char[] weapon)
{
	int flagsgive = GetCommandFlags("give");
	SetCommandFlags("give", flagsgive & ~FCVAR_CHEAT);
	if (IsClientInGame(client))
	{
		char sCmd[64];
		Format(sCmd, sizeof(sCmd), "give %s", weapon);
		FakeClientCommand(client, sCmd);
	}
	SetCommandFlags("give", flagsgive|FCVAR_CHEAT);
}


public void SpawnItem(const char[] class, float position[3], float angle[3])
{
	if (StrEqual(class, "weapon_propanetank"))
	{
		int entity = CreateEntityByName("prop_physics");
		SetEntityModel(entity, "models/props_junk/propanecanister001a.mdl");
		DispatchKeyValue(entity, "CanObstructNav", "0"); // Should remove the entity from blocking navigation?
		TeleportEntity(entity, position, angle, NULL_VECTOR);
		DispatchSpawn(entity);
		
		// Set the m_hOwnerEntity for propane/fireworks. Setting this seems to create propane that move around as their supposed to (e.g. don't slide around whenever a survivor touches them).
		SetEntProp(entity, Prop_Send, "m_hOwnerEntity", g_iOwnerEntity);
	}
	else if (StrEqual(class, "weapon_gascan"))
	{
		int index = CreateEntityByName(class);
		TeleportEntity(index, position, angle, NULL_VECTOR);
		DispatchKeyValue(index, "CanObstructNav", "0"); // Should remove the entity from blocking navigation?
		DispatchSpawn(index);
	}
	else if (StrEqual(class, "weapon_fireworkcrate"))
	{
		int entity = CreateEntityByName("prop_physics");
		SetEntityModel(entity, "models/props_junk/explosive_box001.mdl");
		DispatchKeyValue(entity, "CanObstructNav", "0"); // Should remove the entity from blocking navigation?
		TeleportEntity(entity, position, angle, NULL_VECTOR);
		DispatchSpawn(entity);
		
		// Set the m_hOwnerEntity for propane/fireworks. Setting this seems to create firework crates that move around as their supposed to (e.g. don't slide around whenever a survivor touches them).
		SetEntProp(entity, Prop_Send, "m_hOwnerEntity", g_iOwnerEntity);
	}
	else if (StrEqual(class, "upgrade_ammo_incendiary"))
	{
		int entity = CreateEntityByName("upgrade_ammo_incendiary");
		SetEntityModel(entity, "models/props/terror/incendiary_ammo.mdl");
		DispatchKeyValue(entity, "CanObstructNav", "0"); // Should remove the entity from blocking navigation?
		TeleportEntity(entity, position, angle, NULL_VECTOR);
		DispatchSpawn(entity);
	}
	else if (StrEqual(class, "upgrade_ammo_explosive"))
	{
		int entity = CreateEntityByName("upgrade_ammo_explosive");
		SetEntityModel(entity, "models/props/terror/exploding_ammo.mdl");
		DispatchKeyValue(entity, "CanObstructNav", "0"); // Should remove the entity from blocking navigation?
		TeleportEntity(entity, position, angle, NULL_VECTOR);
		DispatchSpawn(entity);
	}
	
	// undeployed special ammo. Needed for when default spawns automatically get saved
	else if (StrEqual(class, "weapon_upgradepack_incendiary_spawn"))
	{
		int entity = CreateEntityByName("weapon_upgradepack_incendiary_spawn");
		SetEntityModel(entity, "models/w_models/weapons/w_eq_incendiary_ammopack.mdl");
		DispatchKeyValue(entity, "CanObstructNav", "0"); // Should remove the entity from blocking navigation?
		TeleportEntity(entity, position, angle, NULL_VECTOR);
		DispatchSpawn(entity);
	}
	else if (StrEqual(class, "weapon_upgradepack_explosive_spawn"))
	{
		int entity = CreateEntityByName("weapon_upgradepack_explosive_spawn");
		SetEntityModel(entity, "models/w_models/weapons/w_eq_explosive_ammopack.mdl");
		DispatchKeyValue(entity, "CanObstructNav", "0"); // Should remove the entity from blocking navigation?
		TeleportEntity(entity, position, angle, NULL_VECTOR);
		DispatchSpawn(entity);
	}
}

//=============================
// Methods for removing a gas configs
//=============================

public void RemoveGasSetupHandle(int client, char[] sConfigName)
{
	GetCurrentMap(g_sMapName, sizeof(g_sMapName));
	
	char sCfgPath[PLATFORM_MAX_PATH];
	SetKVPath(sConfigName, sCfgPath);
	
	if (FileExists(sCfgPath))
	{
		DeleteFile(sCfgPath);
	}
	else
	{
		PrintToChat(client, "File does not exist");
	}
}

//================================
// Methods for tracking cfg files
//================================

public bool HasConfigs()
{
	GetCurrentMap(g_sMapName, sizeof(g_sMapName));
	
	char path[PLATFORM_MAX_PATH];
	FileType type;
	
	Format(path, sizeof(path), "/addons/sourcemod/data/GasConfigs/%s", g_sMapName);
	
	Handle dir = OpenDirectory(path);
	if (dir == INVALID_HANDLE)
	{
		// Directory doesn't exist, return false
		return false;
	}
	
	char file[PLATFORM_MAX_PATH];
	while (ReadDirEntry(dir, file, sizeof(file), type))
	{
		if (type == FileType_File)
		{
			return true;
		}
	}
	return false;
}

public bool CheckListCount(int client, char[] sName)
{
	char path[PLATFORM_MAX_PATH];
	FileType type;
	int count = 0;

	Format(path, sizeof(path), "/addons/sourcemod/data/GasConfigs/%s", g_sMapName);
	
	Handle dir = OpenDirectory(path);
	if (dir == INVALID_HANDLE)
	{
		// Directory doesn't exist, return false
		if (client > 0) PrintToChat(client, "Can't find directory for this map...");
		return false;
	}
	
	char file[128];
	while (ReadDirEntry(dir, file, sizeof(file), type))
	{
		if (type == FileType_File)
		{
			char cfgName[128];
			SplitString(file, ".", cfgName, sizeof(cfgName));
			if (StrEqual(cfgName, sName))
			{
				if (client > 0) PrintToChat(client, "\x05Gas config \x04%s\x05 already exists.", sName);
				return false;
			}
			count++;
		}
	}
		
	if (count >= g_iMaxSetups)
	{
		if (client > 0) PrintToChat(client, "\x03Already have %i configs for this map. Need to delete one before creating a new one.", g_iMaxSetups);
		return false;
	}
	
	return true;
}
//=============================
// Set Default Config
//=============================

public Action Event_RoundEnd(Handle hEvent, const char[] name, bool dontBroadcast)
{
	g_bRoundStart = false;
}

public Action Event_SurvivalStart(Handle hEvent, const char[] name, bool dontBroadcast)
{
	g_bRoundStart = true;
	
	// disable highlight if it's in progress
	HighlightGasCans(false);

	// LogAction (picked up by another plugin) if more gas items on map than there should be
	CreateTimer(2.0, Timer_CheckGas, INVALID_HANDLE, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_CheckGas(Handle timer)
{
	char sMap[32];
	GetCurrentMap(sMap, sizeof(sMap));

	AreGasItemCountsLegit();

	return Plugin_Handled;
}

public Action Event_RoundStart(Handle hEvent, const char[] name, bool dontBroadcast)
{
	char GameName[16];
	GetConVarString(FindConVar("mp_gamemode"), GameName, sizeof(GameName));
	if (StrContains(GameName, "survival", false) != -1)
	{
		SetDefault();
		g_bHighlightCansToggled = false;
		//Delay so that everything can load before loading the config
		g_iRoundStartLoop = 0;
		CreateTimer(0.1, DefaultGasHandle);

	}
}

public Action DefaultGasHandle(Handle timer)
{
	// stop from calling this function in an infinite loop when the server's empty...
	if (++g_iRoundStartLoop > 800)
	{
		return Plugin_Handled;
	}

	if (!StrEqual(g_sDefaultConfig, ""))
	{
		if (g_bLegitCans)
		{
			bool bFoundSurvivor = false;
			for (int i = 0; i < MAXPLAYERS; i++)
			{
				if (IS_SURVIVOR_ALIVE(i))
				{
					bFoundSurvivor = true;
				}
			}
			
			if (bFoundSurvivor)
			{
				SaveGasSetupHandle(0, "default spawns");
				LoadGasSetupHandle(g_sDefaultConfig, -1);
			}
			else
			{
				// Wait 0.1 seconds and try again
				CreateTimer(0.1, DefaultGasHandle);
			}
		}
		else
		{
			SaveGasSetupHandle(0, "default spawns");
			LoadGasSetupHandle(g_sDefaultConfig, -1);
		}
	}
	// save default gas spawns still on map load. Bit messy I know -dustin 
	else
	{
		bool bFoundSurvivor = false;
		for (int i = 0; i < MAXPLAYERS; i++)
		{
			if (IS_SURVIVOR_ALIVE(i))
			{
				bFoundSurvivor = true;
			}
		}
		if (bFoundSurvivor)
		{
			SaveGasSetupHandle(0, "default spawns");
		}
		else
		{
			// Wait 0.1 seconds and try again
			CreateTimer(0.1, DefaultGasHandle);
		}
	}
	return Plugin_Handled;
}

public void SetDefault()
{
	Handle kv = CreateKeyValues("CfgList");
	
	if (!FileToKeyValues(kv, g_sConfigFilePath))
	{
		#if DEBUG
		PrintToChatAll("Couldn't load the CfgList file");
		#endif
		CloseHandle(kv);
		return;
	}
	
	if (!KvJumpToKey(kv, "Default", true))
	{
		#if DEBUG
		PrintToChatAll("Couldn't create keyvalue for this map...");
		#endif
		CloseHandle(kv);
		return;
	}
	
	GetCurrentMap(g_sMapName, sizeof(g_sMapName));
	KvGetString(kv, g_sMapName, g_sDefaultConfig, sizeof(g_sDefaultConfig), "");
	
	CloseHandle(kv);
}

public void SaveDefault(int client, char[] sConfig)
{
	Handle kv = CreateKeyValues("CfgList");
	
	if (!FileToKeyValues(kv, g_sConfigFilePath))
	{
		PrintToChat(client, "Couldn't load the CfgList file");
		return;
	}
	
	if (!KvJumpToKey(kv, "Default", true))
	{
		PrintToChat(client, "Couldn't create keyvalue for this map...");
		return;
	}
	
	PrintToChatAll("\x04%s\x05 set as default gas setup", sConfig);
	KvSetString(kv, g_sMapName, sConfig);
	
	KvRewind(kv);
	
	KeyValuesToFile(kv, g_sConfigFilePath);
	CloseHandle(kv);
}

public void ClearDefault(int client)
{
	Handle kv = CreateKeyValues("CfgList");
	
	if (!FileToKeyValues(kv, g_sConfigFilePath))
	{
		PrintToChat(client, "Couldn't load the CfgList file");
		return;
	}
	
	if (!KvJumpToKey(kv, "Default", true))
	{
		PrintToChat(client, "Couldn't create keyvalue for this map...");
		return;
	}
	
	KvDeleteKey(kv, g_sMapName);
	KvRewind(kv);
	KeyValuesToFile(kv, g_sConfigFilePath);
	CloseHandle(kv);

	PrintToChat(client, "\x05Default gas setup removed");
}

//============================
// Native Functions - I just use this to add the GasMenu as an option in my admin menu
//============================

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
   CreateNative("GasConfigMenu", Native_GasConfigMenu);
   return APLRes_Success;
}

public int Native_GasConfigMenu(Handle plugin, int numParams)
{
	int client;
	client = GetNativeCell(1);
	g_hAdminMenu = GetNativeCell(2);
	g_bAdminMenu[client] = true;
	
	ShowGasConfigMenu(client);
}

//============================
// Menu system
//============================

void ShowGasConfigMenu(int client)
{
	if (IsMapForbidden())
	{
		PrintToChat(client, "Command not available on this map.");
		return;
	}

	Handle menu = CreateMenu(mh_GasConfig, MENU_ACTIONS_DEFAULT);
	SetMenuTitle(menu, "Gas Menu");
	
	// TODO - IsClientWhiteListed necessary ? Gravity's implementation
	if (IsClientRootAdmin(client) || IsClientWhiteListed(client))
	{
		// Only show back button if this menu was accessed through the admin menu
		if (g_bAdminMenu[client])
		{
			SetMenuExitBackButton(menu, true);
		}
		
		AddMenuItem(menu, "Create Gas Config", "Create Gas Config");
		// Only show the rest of the options if there are already gas setups created for the current map
		if (HasConfigs())
		{
			AddMenuItem(menu, "Load Gas Config", "Load Gas Config");
			AddMenuItem(menu, "Set Default Config", "Set Default Config");
			AddMenuItem(menu, "Delete Gas Config", "Delete Gas Config");
		}
		
		AddMenuItem(menu, "Move Gas Here", "Move Gas Here");
		
		// Give admin the option to change between spawning out the gas with the correct movement settings or not.
		if (g_bLegitCans)
		{
			AddMenuItem(menu, "Use Bad Movement Settings", "Use Bad Movement Settings");
		}
		else
		{
			AddMenuItem(menu, "Use Correct Movement Settings", "Use Correct Movement Settings");
		}
	}
	else
	{
		// Don't allow non-admins to move gas after round starts
		if (g_bRoundStart)
		{
			PrintToChat(client, "\x03Non-admins can only move gas before the round begins.");
			CloseHandle(menu);
			return;
		}
		else
		{
			if (HasConfigs())
			{
				AddMenuItem(menu, "Load Gas Config", "Load Gas Config");
			}
			AddMenuItem(menu, "Move Gas Here", "Move Gas Here");
		}
	}
	// personal configs (would've returned before we got here if round was in progress for non-admins)
	if (g_cvUseDBEntry.IntValue)
	{
		AddMenuItem(menu, "personal configs", "personal configs");
	}
	
	AddMenuItem(menu, "Highlight gas items", "Highlight gas items");
	
	DisplayMenu(menu, client, MENU_TIME_FOREVER);
}

public int mh_GasConfig(Handle menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			// Close menu if someone still had it open after round-start
			if (g_bRoundStart && (!IsClientRootAdmin(param1) && !IsClientWhiteListed(param1)))
			{
				PrintToChat(param1, "[SM] Cannot select while round is in progress.");
				return;
			}
			
			//param1 is client, param2 is item
			char item[64];
			GetMenuItem(menu, param2, item, sizeof(item));

			if (StrEqual(item, "Create Gas Config"))
			{
				StartListenForSave(param1);
			}
			else if (StrEqual(item, "Load Gas Config"))
			{
				ShowLoadGasConfigMenu(param1);
			}
			else if (StrEqual(item, "Delete Gas Config"))
			{
				ShowDeleteGasConfigMenu(param1);
			}
			else if (StrEqual(item, "Set Default Config"))
			{
				ShowDefaultConfigMenu(param1);
			}
			else if (StrEqual(item, "Move Gas Here"))
			{
				// prevent someone immediately trying to save a config after moving cans
				int iTime = GetTime();
				if (iTime - g_iPersonalConfigCooldownTime < COOLDOWN_ALLOWANCE)
				{
					PrintToChat(param1, "\x04Please wait to use this command.");
					ShowGasConfigMenu(param1);
					return;
				}
				g_iPersonalConfigCooldownTime = GetTime();
				
				MoveCansToClient(param1);
				ShowGasConfigMenu(param1);
			}
			else if (StrEqual(item, "Use Bad Movement Settings"))
			{
				ChangeSpawnType(param1, false);
				ShowGasConfigMenu(param1);
			}
			else if (StrEqual(item, "Use Correct Movement Settings"))
			{
				ChangeSpawnType(param1, true);
				ShowGasConfigMenu(param1);
			}
			else if (StrEqual(item, "personal configs"))
			{
				ShowPersonalConfigsMenu(param1);
			}
			else if (StrEqual(item, "Highlight gas items"))
			{
				if (g_bRoundStart)
				{
					PrintToChat(param1, "[SM] Can't use while round in progress.");
				}
				else
				{
					if (g_bHighlightCansToggled)
					{
						HighlightGasCans(false, false);
					}
					else
					{
						HighlightGasCans(true, false);
					}
					// TODO global reset on map start? round rs?
					PrintToChatAll("\x01[sm_gasmenu] \x03%N\x01 toggled gas items highlight \x04%s", param1, g_bHighlightCansToggled ? "on" : "off");
					
					ShowGasConfigMenu(param1);
				}
			}
		}
		case MenuAction_Cancel:
		{
			if (param2 == MenuCancel_ExitBack)
			{
				DisplayTopMenu(g_hAdminMenu, param1, TopMenuPosition_LastCategory);
			}

		}
		case MenuAction_End:
		{
			CloseHandle(menu);
		}

	}
}

////////////////////
// Config Load Menu
////////////////////
void ShowLoadGasConfigMenu(int client)
{
	Handle menu = CreateMenu(mh_gas_config_load, MENU_ACTIONS_DEFAULT);
	SetMenuTitle(menu, "Load Gas Config");
	SetMenuExitBackButton(menu, true);
	
	char path[PLATFORM_MAX_PATH];
	
	Format(path, sizeof(path), "/addons/sourcemod/data/GasConfigs/%s", g_sMapName);
	
	Handle dir = OpenDirectory(path);
	if (dir == INVALID_HANDLE)
	{
		// Directory doesn't exist, return false
		PrintToChat(client, "\x03Couldn't find any gas setups for this map.");
		return;
	}
	
	FileType type;
	char file[128];
	// Loop through all the gas config files in the directory and add them to the menu
	while (ReadDirEntry(dir, file, sizeof(file), type))
	{
		if (type == FileType_File)
		{
			char cfgName[128];
			SplitString(file, ".", cfgName, sizeof(cfgName)); // remove the file extension..
			AddMenuItem(menu, cfgName, cfgName);
		}
	}
	
	DisplayMenu(menu, client, MENU_TIME_FOREVER);
}

public int mh_gas_config_load(Handle menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			if ((GetUserAdmin(param1) == INVALID_ADMIN_ID) && g_bRoundStart)
			{
				// In case a non-admin had the gas menu open prior the round starting, left it open and waited to run this command until post-round start...
				PrintToChat(param1, "\x03Non-admins can only move gas before the round begins.");
				return;
			}
			if (g_bMovingCans)
			{
				PrintToChat(param1, "\x04Cans are currently being moved.");
				ShowLoadGasConfigMenu(param1);
				return;
			}
			char item[128];
			GetMenuItem(menu, param2, item, sizeof(item));
			
			LoadGasSetupHandle(item, param1);
			ShowLoadGasConfigMenu(param1);
			
			HighlightGasCans();
			PrintToChatAll("\x01Gas config selected: \x04%s", item);
			
			// Logged for sourceTV recorder
			if (g_bRoundStart)
			{
				LogAction(param1, -1, "Gas Config loaded while round in progress.");
			}
		}
		
		case MenuAction_Cancel:
		{
			if (param2 == MenuCancel_ExitBack)
			{
				ShowGasConfigMenu(param1);
			}

		}
		case MenuAction_End:
		{
			CloseHandle(menu);
		}
	}
}

/////////////////
// Config Delete Menu
/////////////////

void ShowDeleteGasConfigMenu(int client)
{
	Handle menu = CreateMenu(mh_gas_config_delete, MENU_ACTIONS_DEFAULT);
	SetMenuTitle(menu, "Delete Gas Config");
	SetMenuExitBackButton(menu, true);
	
	char path[PLATFORM_MAX_PATH];
	FileType type;
	
	Format(path, sizeof(path), "/addons/sourcemod/data/GasConfigs/%s", g_sMapName);
	
	Handle dir = OpenDirectory(path);
	if (dir == INVALID_HANDLE)
	{
		// Directory doesn't exist, return false
		PrintToChat(client, "Can't find directory for this map...");
		return;
	}
	
	char file[128];
	while (ReadDirEntry(dir, file, sizeof(file), type))
	{
		if (type == FileType_File)
		{
			char cfgName[128];
			SplitString(file, ".", cfgName, sizeof(cfgName));
			AddMenuItem(menu, cfgName, cfgName);
		}
	}
	
	DisplayMenu(menu, client, MENU_TIME_FOREVER);
}

public int mh_gas_config_delete(Handle menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			//param1 is client, param2 is item
			char item[128];
			GetMenuItem(menu, param2, item, sizeof(item));
			RemoveGasSetupHandle(param1, item);
			ShowDeleteGasConfigMenu(param1);
		}
		
		case MenuAction_Cancel:
		{
			if (param2 == MenuCancel_ExitBack)
			{
				ShowGasConfigMenu(param1);
			}

		}
		case MenuAction_End:
		{
			CloseHandle(menu);
		}
	}
}

/////////////////
// Personal Config Main Menu
/////////////////

void ShowPersonalConfigsMenu(int client)
{
	Handle menu = CreateMenu(mh_gas_config_personal, MENU_ACTIONS_DEFAULT);
	SetMenuTitle(menu, "Personal Gas Configs");
	SetMenuExitBackButton(menu, true);
	
	AddMenuItem(menu, "Load Gas Config", "Load Gas Config");
	AddMenuItem(menu, "Create Gas Config", "Create Gas Config");
	AddMenuItem(menu, "Delete Gas Config", "Delete Gas Config");
	
	DisplayMenu(menu, client, MENU_TIME_FOREVER);
}

public int mh_gas_config_personal(Handle menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			// Close menu if someone still had it open after round-start
			if (g_bRoundStart)
			{
				PrintToChat(param1, "[SM] Cannot use gas menu while round is in progress.");
				return;
			}
			
			if (g_bMovingCans)
			{
				PrintToChat(param1, "\x04Cans are currently being moved. Wait a sec.");
				return;
			}
			
			char item[128];
			GetMenuItem(menu, param2, item, sizeof(item));
			if (StrEqual(item, "Create Gas Config"))
			{
				if (AreGasItemCountsLegit(param1))
				{
					g_bPersonalConfig = true;
					StartListenForSave(param1);
				}
				ShowPersonalConfigsMenu(param1);
			}
			else if (StrEqual(item, "Delete Gas Config"))
			{
				ShowPersonalDeleteMenu(param1);
			}

			else if (StrEqual(item, "Load Gas Config"))
			{
				ShowPersonalLoadMenu(param1);
			}
		}
		
		case MenuAction_Cancel:
		{
			if (param2 == MenuCancel_ExitBack)
			{
				ShowGasConfigMenu(param1);
			}

		}
		case MenuAction_End:
		{
			CloseHandle(menu);
		}

	}
}

void ShowPersonalDeleteMenu(int client)
{
	char sQuery[MAX_QUERY_LENGTH];
	
	char sMap[32], sAuthID[32];
	GetCurrentMap(sMap, sizeof(sMap));
	
	if (!GetClientAuthId(client, AuthId_SteamID64, sAuthID, sizeof(sAuthID)))
	{
		PrintToChat(client, "[SM] Error retrieving your steam ID, Steam network probably is down.");
		return;
	}
	
	Format(sQuery, sizeof(sQuery), "SELECT DISTINCT BINARY config_name from `%s` WHERE owner = '%s' AND map = '%s';", g_sDBTable, sAuthID, sMap);
	
	g_hDatabase.Query(TQuery_ListConfigs_ForDeletion, sQuery, GetClientUserId(client));
}

public void TQuery_ListConfigs_ForDeletion(Database db, DBResultSet results, const char[] error, any data)
{
	int client = GetClientOfUserId(data);
	if (!client) return;
	
	if (results == null)
	{
		PrintToChat(client, "[SM] There was an error retrieving your configs. Contact an admin is the issue persists.");
		LogError("There was an issue loading client's configs: %s", error);
		return;
	}
	
	Handle menu = CreateMenu(mh_gas_config_personal_DeletAConfig, MENU_ACTIONS_DEFAULT);
	SetMenuTitle(menu, "Delete a config");
	SetMenuExitBackButton(menu, true);
	int i;
	while (results.FetchRow())
	{
		char sConfig[64];
		results.FetchString(0, sConfig, sizeof(sConfig));
		AddMenuItem(menu, sConfig, sConfig);
		i++;
	}
	
	if (i == 0)
	{
		CloseHandle(menu);
		// Go back to personal menu
		PrintToChat(client, "[SM] No configs to display.");
		ShowPersonalConfigsMenu(client);
	}
	else
	{
		DisplayMenu(menu, client, MENU_TIME_FOREVER);
	}
}

public int mh_gas_config_personal_DeletAConfig(Handle menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			// Close menu if someone still had it open after round-start
			if (g_bRoundStart)
			{
				PrintToChat(param1, "[SM] Cannot use gas menu while round is in progress.");
				return;
			}
			if (g_PersonalQueryBeingLogged)
			{
				PrintToChat(param1, "[SM] Another personal config is being processed. Wait a sec.");
				ShowPersonalDeleteMenu(param1);
				return;
			}
			
			char item[128];
			GetMenuItem(menu, param2, item, sizeof(item));
			
			char sMap[32], sAuthID[32];
			GetCurrentMap(sMap, sizeof(sMap));
			if (!GetClientAuthId(param1, AuthId_SteamID64, sAuthID, sizeof(sAuthID)))
			{
				PrintToChat(param1, "[SM] Error retrieving your steam ID. Steam network is probably down..");
				return;
			}
			
			int size = 2 * strlen(item) + 1;
			char[] sEscapedConfigName = new char[size];
			g_hDatabase.Escape(item, sEscapedConfigName, size);
			
			char sQuery[MAX_QUERY_LENGTH];
			Format(sQuery, sizeof(sQuery), "DELETE FROM `%s` WHERE BINARY config_name = '%s' AND map = '%s' AND owner = '%s';", g_sDBTable, sEscapedConfigName, sMap, sAuthID);
			
			g_PersonalQueryBeingLogged = true;

			g_hDatabase.Query(TQuery_RemoveConfigResult, sQuery, GetClientUserId(param1));

			g_smQueryValues.Clear();
			g_smQueryValues.SetValue(KEY_USERID, GetClientUserId(param1));
			g_smQueryValues.SetString(KEY_CONFIGNAMEESCAPED, sEscapedConfigName);
			g_smQueryValues.SetString(KEY_MAP, sMap);
			g_smQueryValues.SetString(KEY_LOADERSTEAM64, sAuthID); // loader and owner the same
			g_smQueryValues.SetString(KEY_OWNERSTEAM64ID, sAuthID); // loader and owner the same
			// We want to search the first instance of when a config was created
			// so action = create and order by ID desc incase users save & delete multiple configs with same name (e.g. latest version of "laps" config)
			Format(sQuery, sizeof(sQuery), "SELECT owner_name, config_UniqueID, gas, propane, fireworks, specialAmmo FROM `%s` WHERE BINARY config_name = '%s' AND map = '%s' AND owner_steam64ID = '%s' AND action = '%s' ORDER BY id DESC;", g_sDBTableLog, sEscapedConfigName, sMap, sAuthID, ACTION_CREATE);
			g_hDatabase.Query(DBQuery_RetrieveMetaInfo_load, sQuery);

			DataPack pack = new DataPack();
			pack.WriteString(ACTION_DELETE);
			pack.WriteCell(GetClientUserId(param1));
			CreateTimer(1.0, Timer_FinishLoggingStats, pack);
		}
		
		case MenuAction_Cancel:
		{
			if (param2 == MenuCancel_ExitBack)
			{
				ShowPersonalConfigsMenu(param1);
			}

		}
		case MenuAction_End:
		{
			CloseHandle(menu);
		}
	}
}

public void TQuery_RemoveConfigResult(Database db, DBResultSet results, const char[] error, any data)
{
	int client = GetClientOfUserId(data);
	
	if (results == null)
	{
		PrintToChat(client, "MySQL DB error, contact an admin if the issue persists");
		LogError("MySQL DB error: %s", error);
		return;
	}
	
	PrintToChat(client, "[SM] Config Removed successfully");
	ShowPersonalDeleteMenu(client);
}

/////////////////
// Personal Config Load Menu
/////////////////
void ShowPersonalLoadMenu(int client)
{
	char sQuery[MAX_QUERY_LENGTH];
	
	char sMap[32], sAuthID[32];
	GetCurrentMap(sMap, sizeof(sMap));
	
	if (!GetClientAuthId(client, AuthId_SteamID64, sAuthID, sizeof(sAuthID)))
	{
		PrintToChat(client, "[SM] Error retrieving your steam ID, Steam network probably is down.");
		return;
	}
	
	Format(sQuery, sizeof(sQuery), "SELECT DISTINCT BINARY config_name from `%s` WHERE owner = '%s' AND map = '%s';", g_sDBTable, sAuthID, sMap);
	
	g_hDatabase.Query(TQuery_ListConfigs, sQuery, GetClientUserId(client));
}

public void TQuery_ListConfigs(Database db, DBResultSet results, const char[] error, any data)
{
	int client = GetClientOfUserId(data);
	if (!client) return;
	
	if (results == null)
	{
		PrintToChat(client, "[SM] There was an error retrieving your configs. Contact an admin is the issue persists.");
		LogError("There was an issue loading client's configs: %s", error);
		return;
	}
	
	Handle menu = CreateMenu(mh_gas_config_personal_LoadAConfig, MENU_ACTIONS_DEFAULT);
	SetMenuTitle(menu, "Load a config");
	SetMenuExitBackButton(menu, true);
	int i;
	while (results.FetchRow())
	{
		char sConfig[64];
		results.FetchString(0, sConfig, sizeof(sConfig));
		AddMenuItem(menu, sConfig, sConfig);
		i++;
	}
	
	if (i == 0)
	{
		CloseHandle(menu);
		// Go back to personal menu
		PrintToChat(client, "[SM] No configs to display.");
		ShowPersonalConfigsMenu(client);
	}
	else
	{
		DisplayMenu(menu, client, MENU_TIME_FOREVER);
	}
}

public int mh_gas_config_personal_LoadAConfig(Handle menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			// Close menu if someone still had it open after round-start
			if (g_bRoundStart)
			{
				PrintToChat(param1, "[SM] Cannot use gas menu while round is in progress.");
				return;
			}
			
			// prevent someone from spamming up the database
			int iTime = GetTime();
			if (iTime - g_iPersonalConfigCooldownTime < COOLDOWN_ALLOWANCE)
			{
				PrintToChat(param1, "\x04Please wait to use this command.");
				ShowPersonalLoadMenu(param1);
				return;
			}
			g_iPersonalConfigCooldownTime = GetTime();

			char item[128];
			GetMenuItem(menu, param2, item, sizeof(item));
			
			LoadPersonalGasConfig_prep(item, param1);
			PrintToChatAll("\x03%N\x01 loaded personal gas config: \x04%s", param1, item);
			
			ShowPersonalLoadMenu(param1);
		}
		
		case MenuAction_Cancel:
		{
			if (param2 == MenuCancel_ExitBack)
			{
				ShowPersonalConfigsMenu(param1);
			}

		}
		case MenuAction_End:
		{
			CloseHandle(menu);
		}
	}
}

//=========================
// Default menu
//=========================

void ShowDefaultConfigMenu(int client)
{
	Handle menu = CreateMenu(mh_gas_config_default, MENU_ACTIONS_DEFAULT);
	SetMenuTitle(menu, "Set Default Config");
	SetMenuExitBackButton(menu, true);
	
	AddMenuItem(menu, "Normal Gas Spawns", "Normal Gas Spawns");
	
	char path[PLATFORM_MAX_PATH];
	FileType type;
	
	Format(path, sizeof(path), "/addons/sourcemod/data/GasConfigs/%s", g_sMapName);
	
	Handle dir = OpenDirectory(path);
	if (dir == INVALID_HANDLE)
	{
		// Directory doesn't exist, return false
		PrintToChat(client, "Can't find directory for this map...");
		return;
	}
	
	char file[128];
	while (ReadDirEntry(dir, file, sizeof(file), type))
	{
		if (type == FileType_File)
		{
			char cfgName[128];
			SplitString(file, ".", cfgName, sizeof(cfgName));
			AddMenuItem(menu, cfgName, cfgName);
		}
	}
	
	DisplayMenu(menu, client, MENU_TIME_FOREVER);
}

public int mh_gas_config_default(Handle menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char item[128];
			GetMenuItem(menu, param2, item, sizeof(item));
			if (StrEqual(item, "Normal Gas Spawns"))
			{
				ClearDefault(param1);
			}
			else
			{
				SaveDefault(param1, item);
			}
			ShowDefaultConfigMenu(param1);
		}
		
		case MenuAction_Cancel:
		{
			if (param2 == MenuCancel_ExitBack)
			{
				ShowGasConfigMenu(param1);
			}
		}
		case MenuAction_End:
		{
			CloseHandle(menu);
		}

	}
}

//=========================
// Database methods and logic
//=========================

public void OnSQLConnect(Database db, const char[] error, any data)
{
	if (db == null)
	{
		// TODO for some reason had to RS the server to get this cvar reset, reloading the plugin didn't work (was testing a bad DB password).
		g_cvUseDBEntry.SetInt(0);
		LogError("Error connecting to database: %s", error);
		return;
	}

	//Double check that we don't already have a connection.
	if (g_hDatabase != null)
	{
		delete db;
		return;
	}
	
	g_hDatabase = db;
	LogMessage("[GasConfig] Connected to the database successfully.");
	
	DBDriver driver = db.Driver;
	char sDriverIdent[16];
	driver.GetIdentifier(sDriverIdent, sizeof(sDriverIdent));
	
	// Set the right character set in mysql
	if(StrEqual(sDriverIdent, "mysql", false))
	{
		// Fallback to just utf8 until SourceMod's client libraries are updated.
		if (!g_hDatabase.SetCharset("utf8mb4"))
		{
			#if DEBUG
			LogToFile(g_sDebugLog, "[debug] DB failed to set 'utf8mb4' charset. Resorting back to utf8");
			#endif
			g_hDatabase.SetCharset("utf8");
		}
	}

	Transaction trans = new Transaction();
	
	char sQuery[MAX_QUERY_LENGTH];

	Format(sQuery, sizeof(sQuery), "CREATE TABLE IF NOT EXISTS `%s` (\
	`id` BIGINT(11) UNSIGNED NOT NULL AUTO_INCREMENT, \
	`config_name` VARCHAR(64) NOT NULL DEFAULT '', \
	`config_UniqueID` varchar(64) NOT NULL DEFAULT '', \
	`owner` VARCHAR(32) NOT NULL DEFAULT '', \
	`map` VARCHAR(32) NOT NULL DEFAULT '', \
	`entity` VARCHAR(64) NOT NULL DEFAULT '', \
	`pos0` VARCHAR(20) NOT NULL DEFAULT '', \
	`pos1` VARCHAR(20) NOT NULL DEFAULT '', \
	`pos2` VARCHAR(20) NOT NULL DEFAULT '', \
	`ang0` VARCHAR(20) NOT NULL DEFAULT '', \
	`ang1` VARCHAR(20) NOT NULL DEFAULT '', \
	`ang2` VARCHAR(20) NOT NULL DEFAULT '', \
	`date` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, \
	PRIMARY KEY(id));", g_sDBTable);
	trans.AddQuery(sQuery);

	Format(sQuery, sizeof(sQuery), "CREATE TABLE IF NOT EXISTS `%s` (\
	`id` int(11) unsigned NOT NULL AUTO_INCREMENT, \
	`owner_name` varchar(64) NOT NULL DEFAULT '', \
	`owner_steam64ID` varchar(32) NOT NULL DEFAULT '', \
	`name_user_who_loaded_config` varchar(64) NOT NULL DEFAULT '', \
	`steam64ID_user_who_loaded_config` varchar(32) NOT NULL DEFAULT '', \
	`action` varchar(16) NOT NULL DEFAULT '', \
	`config_UniqueID` varchar(64) NOT NULL DEFAULT '', \
	`config_name` varchar(64) NOT NULL DEFAULT '', \
	`is_config_active` tinyint(11) NOT NULL DEFAULT '1', \
	`map` varchar(24) NOT NULL, \
	`server_name` varchar(32) NOT NULL DEFAULT '', \
	`server_ip` varchar(24) NOT NULL DEFAULT '', \
	`gas` smallint(11) unsigned, \
	`propane` smallint(11) unsigned, \
	`fireworks` smallint(11) unsigned, \
	`specialAmmo` smallint(11) unsigned, \
	`date` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, \
	PRIMARY KEY(id));", g_sDBTableLog);
	trans.AddQuery(sQuery);

	//g_hDatabase.Query(TQuery_CreateDBTable, sQuery);
	g_hDatabase.Execute(trans, INVALID_FUNCTION, DBCreate_Failure);
}

public void DBCreate_Failure(Database db, DataPack pack, int numQueries, const char[] error, int failIndex, any[] queryData)
{
	LogError("Error connecting to DB or creating tables: %s", error);
}

/*public void TQuery_CreateDBTable(Database db, DBResultSet results, const char[] error, any data)
{
	if (results == null)
	{
		LogError("Error creating tables: %s", error);
	}
}*/

void SaveGasConfigToDB(int client, char[] sConfigName)
{
	// trim off whitespace before length check
	TrimString(sConfigName);

	if (g_bMovingCans)
	{
		PrintToChat(client, "\x04Cans are currently being moved. Wait a sec.");
		return;
	}
	
	// some idiots may try saving emoji names or weird UTF-8 characters which might not render in menus
	if (g_regex.Match(sConfigName) > 0)
	{
		PrintToChat(client, "[SM] Config name can only contain ASCII characters.");
		return;
	}
	
	// Names over 15 characters might look funky on the menu
	int len = strlen(sConfigName);
	if (len < 2 || len > 15)
	{
		PrintToChat(client, "[SM] config name must be between 2-15 characters.");
		return;
	}
	
	char sMap[32], sAuthID[32], sName[54];
	GetCurrentMap(sMap, sizeof(sMap));
	GetClientName(client, sName, sizeof(sName));
	if (!GetClientAuthId(client, AuthId_SteamID64, sAuthID, sizeof(sAuthID)))
	{
		PrintToChat(client, "[SM] Error retrieving your steam ID. Steam network is probably down..");
		return;
	}
	
	int size = 2 * strlen(sConfigName) + 1;
	char[] sEscapedConfigName = new char[size];
	g_hDatabase.Escape(sConfigName, sEscapedConfigName, size);

	size = 2 * strlen(sName) + 1;
	char[] sEscapedPlayerName = new char[size];
	g_hDatabase.Escape(sName, sEscapedPlayerName, size);
	
	// Make sure there's not already a config with that name for current map & player..
	char sQuery[MAX_QUERY_LENGTH];
	Format(sQuery, sizeof(sQuery), "SELECT DISTINCT BINARY config_name FROM `%s` WHERE map = '%s' AND owner = '%s';", g_sDBTable, sMap, sAuthID);
	
	DataPack pack = new DataPack();
	pack.WriteCell(GetClientUserId(client));
	pack.WriteString(sEscapedConfigName);
	pack.WriteString(sMap);
	pack.WriteString(sAuthID);
	pack.WriteString(sEscapedPlayerName);
	
	g_hDatabase.Query(TQuery_CheckIfConfigExists, sQuery, pack);
}

public void TQuery_CheckIfConfigExists(Database db, DBResultSet results, const char[] error, DataPack pack)
{
	pack.Reset();
	int client = GetClientOfUserId(pack.ReadCell());
	char sConfigName_Escaped[124], sMap[32], sAuthID[32], sPlayernameEscaped[64];
	pack.ReadString(sConfigName_Escaped, sizeof(sConfigName_Escaped));
	pack.ReadString(sMap, sizeof(sMap));
	pack.ReadString(sAuthID, sizeof(sAuthID));
	pack.ReadString(sPlayernameEscaped, sizeof(sPlayernameEscaped));
	
	if (results == null)
	{
		LogError("MySQL DB error: %s", error);
		delete pack;
		PrintToChat(client, "[SM] MySQL error. Contact admin if the issue persists.");
		return;
	}
	
	int iNumOfConfigsOnRecord;
	
	while (results.FetchRow())
	{
		iNumOfConfigsOnRecord++;
		
		char sConfigName[64];
		results.FetchString(0, sConfigName, sizeof(sConfigName));
		
		// We're comparing against an escaped name so need to escape this first
		// otherwise names like "/\`*'" would fail this check
		int size = 2 * strlen(sConfigName) + 1;
		char[] sEscapedConfigName2 = new char[size];
		g_hDatabase.Escape(sConfigName, sEscapedConfigName2, size);
		
		if (StrEqual(sEscapedConfigName2, sConfigName_Escaped))
		{
			PrintToChat(client, "[SM] Gas config already exists with that name.");
			delete pack;
			return;
		}
		
		if (iNumOfConfigsOnRecord == g_cvPersonalConfigLimit.IntValue && g_cvPersonalConfigLimit.IntValue != -1)
		{
			PrintToChat(client, "\x01[SM] Max amount of configs reached for this map: \x04%i", iNumOfConfigsOnRecord);
			PrintToChat(client, "Remove a config to save a new one.");
			delete pack;
			return;
		}
	}

	SaveConfigToDB(client, sConfigName_Escaped, sMap, sAuthID, sPlayernameEscaped);
	delete pack;
}

void SaveConfigToDB(int client, const char[] sConfigName_Escaped, const char[] sMap, const char[] sAuthID, const char[] sPlayerNameEscaped)
{
	char sConfigID[64], sServerIP[32];
	GenerateConfigID(sConfigID, sizeof(sConfigID), sAuthID);

	// escape hostname
	int size = 2 * strlen(g_sHostName) + 1;
	char[] sEscapedHostName = new char[size];
	g_hDatabase.Escape(g_sHostName, sEscapedHostName, size);

	// Sets g_iGasCanCount, iPropaneCount, iFireworkCount, iSpecialAmmoCount
	CountGasItems();

	Transaction trans = new Transaction();
	char sQuery[MAX_QUERY_LENGTH];
	
	int iEnt = -1;
	float position[3];
	float angle[3];
	
	for (int i = 0; i < NUM_CANS_TYPES; i++)
	{
		while ((iEnt = FindEntityByClassname(iEnt, UniqueClassNames[i])) != -1)
		{
			if (!IsValidEdict(iEnt) || !IsValidEntity(iEnt)) continue;
			
			if (IsEntityConstructionSiteRadio(iEnt)) continue;
			
			GetEntPropVector(iEnt, Prop_Send, "m_vecOrigin", position);
			GetEntPropVector(iEnt, Prop_Send, "m_angRotation", angle);
			
			Format(sQuery, sizeof(sQuery), "INSERT INTO `%s` (config_name, config_UniqueID, owner, map, entity, pos0, pos1, pos2, ang0, ang1, ang2) VALUES ('%s', '%s', '%s', '%s', '%s', '%f', '%f', '%f', '%f', '%f', '%f');", g_sDBTable, sConfigName_Escaped, sConfigID, sAuthID, sMap, UniqueClassNames[i], position[0], position[1], position[2], angle[0], angle[1], angle[2]);
			trans.AddQuery(sQuery);
		}
	}
	
	char sEntModel[128];
	// Second loop for prop_physics objects since we need to look at the model name
	while ((iEnt = FindEntityByClassname(iEnt, "prop_physics")) != -1) 
	{
		if (!IsValidEdict(iEnt) || !IsValidEntity(iEnt)) continue;
		
		if (IsEntityConstructionSiteRadio(iEnt)) continue;
		
		GetEntPropString(iEnt, Prop_Data, "m_ModelName", sEntModel, sizeof(sEntModel)); 
		for (int i = 0; i < NUM_MODEL_TYPES; i++)
		{
			if (StrEqual(sEntModel, ModelNames[i], false)) 
			{
				if (view_as<bool>(GetEntProp(iEnt, Prop_Send, "m_isCarryable", 1)))
				{
					GetEntPropVector(iEnt, Prop_Send, "m_vecOrigin", position);
					GetEntPropVector(iEnt, Prop_Send, "m_angRotation", angle);
			
					Format(sQuery, sizeof(sQuery), "INSERT INTO `%s` (config_name, config_UniqueID, owner, map, entity, pos0, pos1, pos2, ang0, ang1, ang2) VALUES ('%s', '%s', '%s', '%s', '%s', '%f', '%f', '%f', '%f', '%f', '%f');", g_sDBTable, sConfigName_Escaped, sConfigID, sAuthID, sMap, ClassNames[i], position[0], position[1], position[2], angle[0], angle[1], angle[2]);
					trans.AddQuery(sQuery);
					continue; // TODO - was in original plugin. Why is this here?
				}
			}
		}
	}

	Format(sQuery, sizeof(sQuery), "INSERT INTO `%s` (\
			owner_name, \
			owner_steam64ID, \
			name_user_who_loaded_config, \
			steam64ID_user_who_loaded_config, \
			action, \
			config_UniqueID, \
			config_name, \
			map, \
			server_name, \
			server_ip, \
			gas, \
			propane, \
			fireworks, \
			specialAmmo) \
			VALUES (\
			'%s', \
			'%s', \
			'%s', \
			'%s', \
			'%s', \
			'%s', \
			'%s', \
			'%s', \
			'%s', \
			'%s', \
			'%i', \
			'%i', \
			'%i', \
			'%i'\
			);", g_sDBTableLog, sPlayerNameEscaped, sAuthID, sPlayerNameEscaped, sAuthID, ACTION_CREATE, sConfigID, sConfigName_Escaped, sMap, sEscapedHostName, sServerIP, g_iGasCanCount, iPropaneCount, iFireworkCount, iSpecialAmmoCount);
	trans.AddQuery(sQuery);
	
	g_hDatabase.Execute(trans, SaveGasConfig_Success, SaveGasConfig_Failure, GetClientUserId(client));
}

public void SaveGasConfig_Success(Database db, int userID, int numQueries, DBResultSet[] results, any[] queryData)
{
	int client = GetClientOfUserId(userID);
	PrintToChat(client, "[SM] Gas config successfully saved.");
}

public void SaveGasConfig_Failure(Database db, int userID, int numQueries, const char[] error, int failIndex, any[] queryData)
{
	int client = GetClientOfUserId(userID);
	PrintToChat(client, "[SM] There was an error trying to save the config. Contact an admin.");
	LogError("Error saving gas config: %s", error);
}

void LoadPersonalGasConfig_prep(const char[] sConfigName, int client)
{
	char sMap[32], sAuthID[32];
	GetCurrentMap(sMap, sizeof(sMap));
	
	if (!GetClientAuthId(client, AuthId_SteamID64, sAuthID, sizeof(sAuthID)))
	{
		PrintToChat(client, "[SM] Error retrieving your steam ID, Steam network probably is down.");
		return;
	}

	if (g_PersonalQueryBeingLogged)
	{
		PrintToChat(client, "[SM] Another personal config is being processed. Wait a sec.");
		ShowPersonalConfigsMenu(client);
		return;
	}

	if (g_bMovingCans)
	{
		PrintToChat(client, "\x04Cans are currently being moved. Wait a sec.");
		ShowPersonalConfigsMenu(client);
		return;
	}

	g_PersonalQueryBeingLogged = true;
	
	int size = 2 * strlen(sConfigName) + 1;
	char[] sEscapedConfigName = new char[size];
	g_hDatabase.Escape(sConfigName, sEscapedConfigName, size);
	
	char sQuery[MAX_QUERY_LENGTH];
	Format(sQuery, sizeof(sQuery), "SELECT * FROM `%s` WHERE BINARY config_name = '%s' AND map = '%s' AND owner = '%s';", g_sDBTable, sEscapedConfigName, sMap, sAuthID);

	g_hDatabase.Query(TQuery_LoadPersonalGasConfig, sQuery, GetClientUserId(client));

	// Log personal gas config usage to seperate log table
	g_smQueryValues.Clear();
	g_smQueryValues.SetValue(KEY_USERID, GetClientUserId(client));
	g_smQueryValues.SetString(KEY_CONFIGNAMEESCAPED, sEscapedConfigName);
	g_smQueryValues.SetString(KEY_MAP, sMap);
	g_smQueryValues.SetString(KEY_LOADERSTEAM64, sAuthID); // loader and owner the same
	g_smQueryValues.SetString(KEY_OWNERSTEAM64ID, sAuthID); // loader and owner the same

	/*
	Need to retrieve: owner_name, owner_steam64ID, config_UniqueID, gas, propane, fireworks, specialAmmo 
		before logging a loadout into the DB again
	Order by id desc to get latest config incase users are making configs with same name over and over 
		(e.g. only want to get the latest version of 'laps'), when they originally created their config (ACTION_CREATE)
	*/
	Format(sQuery, sizeof(sQuery), "SELECT owner_name, config_UniqueID, gas, propane, fireworks, specialAmmo FROM `%s` WHERE BINARY config_name = '%s' AND map = '%s' AND owner_steam64ID = '%s' AND action = '%s' ORDER BY id DESC;", g_sDBTableLog, sEscapedConfigName, sMap, sAuthID, ACTION_CREATE);
	g_hDatabase.Query(DBQuery_RetrieveMetaInfo_load, sQuery);

	// Can't execute this right after DB query. Slight delay
	DataPack pack = new DataPack();
	pack.WriteString(ACTION_LOAD);
	pack.WriteCell(GetClientUserId(client));
	CreateTimer(1.0, Timer_FinishLoggingStats, pack);
}

public Action Timer_FinishLoggingStats(Handle timer, DataPack pack)
{
	pack.Reset();

	char sAction[16];
	pack.ReadString(sAction, sizeof(sAction));
	int client = GetClientOfUserId(pack.ReadCell());

	int iPreviousQueryReturnedResults;
	g_smQueryValues.GetValue(KEY_PHR, iPreviousQueryReturnedResults);
	if (iPreviousQueryReturnedResults > 0)
	{
		logDBUsage(sAction);
	}
	else
	{
		if (StrEqual(sAction, ACTION_MANUlLOAD))
		{
			PrintToChat(client, "[SM] No results returned for that steamID and config name.");
		}
		else
		{
			LogError("Error logging personal config usage to DB. Might need to increase timer that calls 'Timer_FinishLoggingStats()'");
		}
	}

	g_PersonalQueryBeingLogged = false;
	delete pack;
	return Plugin_Handled;
}

// Most of this was a copy / paste from LoadGasConfig()
public void TQuery_LoadPersonalGasConfig(Database db, DBResultSet results, const char[] error, int userID)
{
	int client = GetClientOfUserId(userID);
	
	if (results == null)
	{
		PrintToChat(client, "MySQL DB error, contact an admin if the issue persists");
		LogError("MySQL DB error: %s", error);
		return;
	}
	
	// Reset our tracking of which entities are in the middle of being killed
	ClearTrie(g_hDeletedEnts);
	
	// Always remove existing special ammo and let the plugin re-place them in the "correct" location
	RemoveNonGasSpawns();
	
	// Initialize some stuff
	Handle hGasList = CreateStack(6);
	Handle hPropaneList = CreateStack(6);
	Handle hFireworkList = CreateStack(6);
	
	int numGas = 0;
	int numPropane = 0;
	int numFireworks = 0;
	
	char class[64];
	float position[3];
	float angle[3];

	while (results.FetchRow())
	{
		results.FetchString(5, class, sizeof(class));
		position[0] = results.FetchFloat(6);
		position[1] = results.FetchFloat(7);
		position[2] = results.FetchFloat(8);
		angle[0] = results.FetchFloat(9);
		angle[1] = results.FetchFloat(10);
		angle[2] = results.FetchFloat(11);
		
		// Track the gas/propane/fireworks in a stack. Need special handling to spawn these out with the correct settings.
		if (StrEqual(class, WeaponNames[view_as<WeaponId>(WEPID_GASCAN)]))
		{
			AddToStack(hGasList, position, angle);
			numGas++;
		}
		else if (StrEqual(class, WeaponNames[view_as<WeaponId>(WEPID_PROPANE_TANK)]))
		{
			AddToStack(hPropaneList, position, angle);
			numPropane++;
		}
		else if (StrEqual(class, WeaponNames[view_as<WeaponId>(WEPID_FIREWORKS_BOX)]))
		{
			AddToStack(hFireworkList, position, angle);
			numFireworks++;
		}
		else
		{
			// Non-gas related items (ie. special ammo) can be spawned out right away
			SpawnItem(class, position, angle);
		}
	}

	bool bRetakeSurvivor = false;
	// First find a client to give the gas to if needed
	if (client == -1)
	{
		int playerSurvivor = -1;
		// Client didn't run this command - ie. beginning of round or map transition
		for (int i = 0; i < MAXPLAYERS; i++)
		{
			if (IS_SURVIVOR_ALIVE(i))
			{
				if (IsFakeClient(i))
				{
					// Prefer using a bot survivor for this
					client = i;
					break;
				}
				else if (playerSurvivor == -1)
				{
					playerSurvivor = i;
				}
			}
		}
		
		if (client == -1 && playerSurvivor != -1)
		{
			// This is the start of the round and we're using a player. Need to make sure we force the player to retake control of the bot to avoid stupid issues..
			client = playerSurvivor;
			bRetakeSurvivor = true;
		}
	}
	
	// Determine how to spawn out the gas
	if (client == -1 || !UseLegitCanSetup())
	{
		#if DEBUGLOG
		LogMessage("Spawning gas the old way");
		#endif
		/* Don't have a valid survivor or admin wanted to spawn it the old way. Spawn the gas normally. The movement of the gas will be off but whatever... */
		
		// Remove the existing gas from the map
		RemoveGasSpawns();
		
		// Spawn out the gas to the correct location
		while (!IsStackEmpty(hGasList))
		{
			PopStackAndSpawn(hGasList, view_as<WeaponId>(WEPID_GASCAN));
		}
		while (!IsStackEmpty(hPropaneList))
		{
			PopStackAndSpawn(hPropaneList, view_as<WeaponId>(WEPID_PROPANE_TANK));
		}
		while (!IsStackEmpty(hFireworkList))
		{
			PopStackAndSpawn(hFireworkList, view_as<WeaponId>(WEPID_FIREWORKS_BOX));
		}
	}
	else
	{
		/* Spawn out the gas in a way that will cause it to have the correct movement settings */
		#if DEBUGLOG
		LogMessage("Spawning gas cans with the correct movement settings");
		#endif
		
		/*
		PrintToChatAll("Gas: %i - %i", NumSpawns(WeaponId:WEPID_GASCAN), numGas);
		PrintToChatAll("Propane: %i - %i", NumSpawns(WeaponId:WEPID_PROPANE_TANK), numPropane);
		PrintToChatAll("Fireworks: %i - %i", NumSpawns(WeaponId:WEPID_FIREWORKS_BOX), numFireworks);
		*/
		
		bool bNewCans = false;
		if (NumSpawns(view_as<WeaponId>(WEPID_GASCAN)) != numGas ||
			NumSpawns(view_as<WeaponId>(WEPID_PROPANE_TANK)) != numPropane ||
			NumSpawns(view_as<WeaponId>(WEPID_FIREWORKS_BOX)) != numFireworks)
		{
			// Don't have enough cans on the map to use. Will need to spawn new cans which means special handling in order to spawn cans with the correct movements.
			bNewCans = true;
			#if DEBUGLOG
			LogMessage("  Using new cans because numbers don't match up");
			#endif
		}
		else if (g_iOwnerEntity == -1 && (numPropane > 0 || numFireworks > 0))
		{
			// Don't have a valid g_iOwnerEntity property for this map yet. Need to spawn a propane to find one.
			// *TODO* Shouldn't need to remove the gascans if they're already correct
			bNewCans = true;
			#if DEBUGLOG
			LogMessage("  Using new cans becuase g_iOwnerEntity is -1");
			#endif
		}
		else
		{
			// Already have enough cans on the map. Just move them around instead of spawning new ones.
			bNewCans = false;
		}
		
		if (bNewCans)
		{
			/* Give cans to players and force them to drop it to create a can with the correct movement properties */
			#if DEBUGLOG
			LogMessage("Spawning new gas cans");
			#endif
			
			// Get rid of any existing cans
			RemoveGasSpawns();
			
			int weapon	= GetPlayerWeaponSlot(client, 0); // Need to use primary or secondary. Equiping pills or throwables won't work to create proper gascans...
			if (weapon != -1)
			{
				/* Always use primary for now...
				new secondary = GetPlayerWeaponSlot(client, 1);
				if (secondary != -1 && IsWeaponEquipped(secondary))
				{
					bSecondary = true;
					weapon = secondary;
				} */
			}
			
			int iClip = 0;
			int ammo = 0;
			int iPrimType = -1;
			bool bSpawnedSMG = false;
			
			if (weapon == -1)
			{
				bSpawnedSMG = true;
				// give player an smg temporarily because we need to re-equip a primary or secondary for this to work. When a map loads, the player will only have pistols and re-equiping those causes them to duplicate a bunch - at least the way I was doing things...
				int index = CreateEntityByName("weapon_smg");
				DispatchSpawn(index);
				
				EquipPlayerWeapon(client, index);
				
				weapon = index;
			}
			else
			{
				// Track how much ammo the player had
				iClip = GetEntProp(weapon, Prop_Send, "m_iClip1");
				iPrimType = GetEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType");
				ammo = GetEntProp(client, Prop_Send, "m_iAmmo", _, iPrimType);
			}
			
			for (int i = 0; i < numGas; i++)
			{
				GiveItem(client, "weapon_gascan");
				
				// Force player to drop the gascan. Need to do this after every gas can otherwise the movement settings aren't correct. (ie. dropping gas by giving a new gascan isn't the same as dropping gascan from switching weapons).
				EquipPlayerWeapon(client, weapon);	
			}
			GiveItem(client, "weapon_propanetank");
			
			if (bSpawnedSMG)
			{
				// Kill the SMG now that we're done spawning gas
				AcceptEntityInput(weapon, "kill");
			}
			else
			{
				// Used the players gun, so we don't need to kill it but we do need to correct the ammo for it.
				SetEntProp(weapon, Prop_Send, "m_iClip1", iClip, sizeof(iClip));
				if (iPrimType != -1 && ammo > 0)
				{
					SetEntProp(client, Prop_Send, "m_iAmmo", ammo, _, iPrimType);
				}
			}
			
			// Find the m_hOwnerEntity property of the propane that was spawned. Then kill the entity so that we can spawn in new propane and correctly set that property.
			int iEnt;
			while ((iEnt = FindEntityByClassname(iEnt, WeaponNames[view_as<WeaponId>(WEPID_PROPANE_TANK)])) != -1) 
			{
				if (!IsValidEdict(iEnt) || !IsValidEntity(iEnt)) {
					continue;
				}
				
				if (IsEntityConstructionSiteRadio(iEnt)) continue;
				
				// retrieve the m_hOwnerEntity property...
				g_iOwnerEntity = GetEntProp(iEnt, Prop_Send, "m_hOwnerEntity");
				AcceptEntityInput(iEnt, "kill");	// kill it now that we have the owner entity... 
			}
		}
		
		if (bRetakeSurvivor)
		{
			/* 
			 * Force the player used to create gas cans to join spectators and back to survivor in order to avoid having kit/pills stick to them when they die.
			 * This is only needed if the cans are loaded within the first few seconds of the round restarting. I'm assuming if the client was passed in (i.e. someone is manually loading a setup) that they aren't doing it within the first few seconds and we can skip this.
			 * Waiting a full second because this conflicts with the AutoSetup plugin if this runs before that's finished giving out weapons.
			 */
			CreateTimer(1.0, Timer_RetakePlayer, client);
		}
		else if (bNewCans && IS_SURVIVOR_ALIVE(client) && IsFakeClient(client))
		{
			/*
			 * Same problem, but the carrier was a bot (which is what we prefer above) and
			 * a bot can't be forced through spectate/rejoin. Rebuild its kit and pills
			 * instead - that re-attaches them properly so they drop on death rather than
			 * staying stuck to the body and following the camera around.
			 * Same 1 second delay, for the same AutoSetup reason.
			 */
			CreateTimer(1.0, Timer_RefreshBotItems, GetClientUserId(client));
		}

		// Move the gas cans into place
		FindAndMoveGas(view_as<WeaponId>(WEPID_GASCAN), hGasList);
		
		if (bNewCans)
		{
			// Spawn out all the propane - Propane will not be movable for the player that "spawns" them. The other players can still bump the propane. That's just how things work..
			while (!IsStackEmpty(hPropaneList))
			{
				PopStackAndSpawn(hPropaneList, view_as<WeaponId>(WEPID_PROPANE_TANK));
			}
			
			// Spawn out the fireworks
			while (!IsStackEmpty(hFireworkList))
			{
				PopStackAndSpawn(hFireworkList, view_as<WeaponId>(WEPID_FIREWORKS_BOX));
			}
		}
		else
		{
			#if DEBUGLOG
			LogMessage("Moving around existing cans");
			#endif
			// Find and move the existing propane and fireworks
			FindAndMoveGas(view_as<WeaponId>(WEPID_PROPANE_TANK), hPropaneList);
			FindAndMoveGas(view_as<WeaponId>(WEPID_FIREWORKS_BOX), hFireworkList);
		}
	}
	
	HighlightGasCans();
}

//=========================
// misc functions
//=========================

bool IsClientRootAdmin(int client)
{
    return ((GetUserFlagBits(client) & ADMFLAG_ROOT) != 0);
}

// I think gravity disabled this because people could use other commands
// on SN servers that would temporarily set their admin flags and forget to set
// them back, so you'd have trolls making officially listed configs
/*
static bool:IsGenericAdmin(client) {
    return CheckCommandAccess(client, "generic_admin", ADMFLAG_GENERIC, false); 
}
*/

void SetColor(int ent, int color)
{
	SetEntProp(ent, Prop_Send, "m_iGlowType", 3);
	SetEntProp(ent, Prop_Send, "m_glowColorOverride", color);
}

void ClearGlow(int ent)
{
	SetEntProp(ent, Prop_Send, "m_iGlowType", 0);
	SetEntProp(ent, Prop_Send, "m_glowColorOverride", 0);
}

void HighlightGasCans(bool bHighlight = true, bool bTimedTurnOff = true)
{
	if (bHighlight)
	{
		if (g_bRoundStart) return;
		
		if (bTimedTurnOff)
		{
			g_fHighlightTime = GetGameTime();
			CreateTimer(HIGHLIGHT_TIMER, Timer_RemoveHighlight);
		}
	}
	
	g_bHighlightCansToggled = bHighlight;
	
	#define CLASSNAMES	4
	char sClassNames[][] = {"weapon_*", "prop_physics", "upgrade_ammo_*", "upgrade_laser_sight"};
	
	char sModelName[PLATFORM_MAX_PATH];
	for (int i = 0; i < CLASSNAMES; i++)
	{
		int entity = -1;
		
		while ((entity = FindEntityByClassname(entity, sClassNames[i])) != -1)
		{
			if (!IsValidEdict(entity) || !IsValidEntity(entity))
				continue;
			
			if (IsEntityConstructionSiteRadio(entity)) continue;
			
			// weapon_gascan, upgraded ammo packs
			if (StrEqual(sClassNames[i], "weapon_*"))
			{
				GetEdictClassname(entity, sModelName, sizeof(sModelName));
				
				if (StrEqual(sModelName, "weapon_gascan")) 
				{
					if (bHighlight) SetColor(entity, COLOR_RED);
					else ClearGlow(entity);
				}
				
				// in-spawn, loose (out of spawn but not deployed), special ammo upgrade packs
				/* Note: currently this plugin doesn't save '_spawn' special ammo. Leaving here
				in case it gets updated to save undeployed ammo packs in a future update. */
				if (StrEqual(sModelName, "weapon_upgradepack_incendiary") ||
				StrEqual(sModelName, "weapon_upgradepack_incendiary_spawn") ||
				StrEqual(sModelName, "weapon_upgradepack_explosive") ||
				StrEqual(sModelName, "weapon_upgradepack_explosive_spawn")) 
				{
					if (bHighlight) SetColor(entity, COLOR_BLUE);
					else ClearGlow(entity);
				}
			}
			
			// gas cans, fireworks, propane
			if (StrEqual(sClassNames[i], "prop_physics"))
			{
				GetEntPropString(entity, Prop_Data, "m_ModelName", sModelName, sizeof(sModelName));
				
				if (StrContains(sModelName, "gascan") != -1)
				{
					if (bHighlight) SetColor(entity, COLOR_RED);
					else ClearGlow(entity);
				}
				
				if (StrContains(sModelName, "explosive_box001") != -1)
				{
					if (bHighlight) SetColor(entity, COLOR_YELLOW);
					else ClearGlow(entity);
				}
				
				if (StrContains(sModelName, "propanecanister") != -1)
				{
					if (bHighlight) SetColor(entity, COLOR_WHITE);
					else ClearGlow(entity);
				}
			}
			
			if (StrEqual(sClassNames[i], "upgrade_ammo_*"))
			{
				GetEntPropString(entity, Prop_Data, "m_ModelName", sModelName, sizeof(sModelName));
				
				if (StrContains(sModelName, "incendiary_ammo") != -1 ||
					StrContains(sModelName, "exploding_ammo") != -1)
					{
						if (bHighlight) SetColor(entity, COLOR_BLUE);
						else ClearGlow(entity);
					}
			}
			
			// laser sights
			if (StrEqual(sClassNames[i], "upgrade_laser_sight"))
			{
				GetEntPropString(entity, Prop_Data, "m_ModelName", sModelName, sizeof(sModelName));
				
				if (StrContains(sModelName, "laser_sights") != -1)
				{
					if (bHighlight) SetColor(entity, COLOR_BLUE);
					else ClearGlow(entity);
				}
			}
		}
	}
}

public Action Timer_RemoveHighlight(Handle timer)
{
	float fGrace = HIGHLIGHT_TIMER - 0.4;
	
	// In case multiple menu items selected in a row...
	// Easier than trying to invalidate a timer that's in-progress
	if (GetGameTime() - g_fHighlightTime > fGrace)
	{
		// remove the highlight
		HighlightGasCans(false);
	}
	return Plugin_Handled;
}

bool IsClientWhiteListed(int client)
{
	char authID[64];
	if (!GetClientAuthId(client, AuthId_SteamID64, authID, sizeof(authID)))
		return false;
	
	/* whitelisted clients would go here. Can recompile if you want to readd support for whitelisted clients. -dustin
	
	if (StrEqual(authID, ""))
		return true;
	*/
	
	return false;
}

bool IsMapForbidden()
{
	char sMap[32];
	GetCurrentMap(sMap, sizeof(sMap));

	/* c11m4_terminal	- gas cans accessable after round starts */
	/* c8m2_subway 		- one gas can not accessable until after round starts */
	if (StrEqual(sMap, "c11m4_terminal") || StrEqual(sMap, "c8m2_subway"))
		return true;
	
	return false;
}

bool IsStringNumeric(const char[] string)
{
	for (int i = 0; i < strlen(string) -1; i++)
	{
		if (!IsCharNumeric(string[i])) return false;
	}
	return true;
}

/* Called on survival round start or when user saves personal gas config */
bool AreGasItemCountsLegit(int client = -1)
{
	CountGasItems();

	int len;
	char sMap[32], sFormattedMessage[592];
	GetCurrentMap(sMap, sizeof(sMap));
	len += Format(sFormattedMessage, sizeof(sFormattedMessage), "excess gas item counts.");
	CanRules rules;
	bool bAreCountsLegit = true;

	// custom map not defined in config file - ignore
	if (g_MapRules.GetArray(sMap, rules, sizeof(rules)) == false)
	{
		return bAreCountsLegit;
	}
	
	if (g_iGasCanCount > rules.gas)
	{
		len += Format(sFormattedMessage[len], sizeof(sFormattedMessage) - len, " gas: %i/%i", g_iGasCanCount, rules.gas);
		bAreCountsLegit = false;
	}
	if (iPropaneCount > rules.propane)
	{
		len += Format(sFormattedMessage[len], sizeof(sFormattedMessage) - len, " propane: %i/%i", iPropaneCount, rules.propane);
		bAreCountsLegit = false;
	}
	if (iFireworkCount > rules.fireworks)
	{
		len += Format(sFormattedMessage[len], sizeof(sFormattedMessage) - len, " fireworks: %i/%i", iFireworkCount, rules.fireworks);
		bAreCountsLegit = false;
	}
	if (iSpecialAmmoCount > rules.specialAmmo)
	{
		len += Format(sFormattedMessage[len], sizeof(sFormattedMessage) - len, " special ammo: %i/%i", iSpecialAmmoCount, rules.specialAmmo);
		bAreCountsLegit = false;
	}

	if (bAreCountsLegit == false)
	{
		if (client > 0)
		{
			PrintToChat(client, "[SM] Not allowed to save config with %s", sFormattedMessage);
			Format(sFormattedMessage, sizeof(sFormattedMessage), "%L tried to save personal config with %s.", client, sFormattedMessage);
			LogAction(client, -1, sFormattedMessage);
		}
		else
		{
			Format(sFormattedMessage, sizeof(sFormattedMessage), "Survival round started with %s.", sFormattedMessage);
		}
	}

	return bAreCountsLegit;
}


public void CountGasItems()
{
	g_iGasCanCount = iPropaneCount = iFireworkCount = iSpecialAmmoCount = 0;
	int iEnt = -1;
	
	// Look for any gas cans that have been moved around the map
	for (int i = 0; i < NUM_CANS_TYPES; i++)
	{
		while ((iEnt = FindEntityByClassname(iEnt, UniqueClassNames[i])) != -1) 
		{
			if (!IsValidEdict(iEnt) || !IsValidEntity(iEnt)) {
				continue;
			}
			
			if (IsEntityConstructionSiteRadio(iEnt)) continue;
			
			incrementGasCount(UniqueClassNames[i]);
		}
	}
	
	char sEntModel[128];
	// Second loop for prop_physics objects since we need to look at the model name
	while ((iEnt = FindEntityByClassname(iEnt, "prop_physics")) != -1) 
	{
		if (!IsValidEdict(iEnt) || !IsValidEntity(iEnt)) {
			continue;
		}
		
		if (IsEntityConstructionSiteRadio(iEnt)) continue;
		
		GetEntPropString(iEnt, Prop_Data, "m_ModelName", sEntModel, sizeof(sEntModel)); 
		for (int i = 0; i < NUM_MODEL_TYPES; i++)
		{
			if (StrEqual(sEntModel, ModelNames[i], false)) 
			{
				if (view_as<bool>(GetEntProp(iEnt, Prop_Send, "m_isCarryable", 1)))
				{
					incrementGasCount(sEntModel);
					continue;
				}	
			}
		}
	}
}

void incrementGasCount(const char[] sModelOrClassName)
{
	// gas
	if (StrContains(sModelOrClassName, "gascan001a") != -1 || 
		StrContains(sModelOrClassName, "weapon_gascan") != -1)
	{
		g_iGasCanCount++;
	}
	else if (StrContains(sModelOrClassName, "propanecanister001") != -1 ||
			StrContains(sModelOrClassName, "weapon_propanetank") != -1)
	{
		iPropaneCount++;
	}
	else if (StrContains(sModelOrClassName, "weapon_fireworkcrate") != -1)
	{
		iFireworkCount++;
	}
	else if (StrContains(sModelOrClassName, "upgrade_ammo_incendiary") != -1 || 
			StrContains(sModelOrClassName, "upgrade_ammo_explosive") != -1 || 
			StrContains(sModelOrClassName, "weapon_upgradepack_incendiary_spawn") != -1 || 
			StrContains(sModelOrClassName, "weapon_upgradepack_explosive_spawn") != -1)
	{
		iSpecialAmmoCount++;
	}
}

void GenerateConfigID(char[] sBuffer, int size, const char[] sSteamID)
{
	char sTmpBuffer[320];

	// Just need a unique name for config_ID column that won't be the same ever.
	Format(sTmpBuffer, sizeof(sTmpBuffer), "%s_%i%i%i%i", sSteamID, GetTime(), GetRandomInt(0, 9999), GetRandomInt(0, 9999), GetRandomInt(0, 9999));
	strcopy(sBuffer, size, sTmpBuffer);
}

void logDBUsage(const char[] sAction)
{
	char sConfigID[64], sConfigNameEscaped[64], sServerIP[32], sMap[32];
	char sSteamID_Loader[24], sSteamID_Owner[24], sEscapedOwnerName[64];
	int userid, gas, propane, fireworks, specialAmmo;

	if (!g_smQueryValues.GetString(KEY_CONFIGID, sConfigID, sizeof(sConfigID))) LogError("logDBUsage() No value associated with key: '%s'", KEY_CONFIGID);
	if (!g_smQueryValues.GetString(KEY_CONFIGNAMEESCAPED, sConfigNameEscaped, sizeof(sConfigNameEscaped))) LogError("logDBUsage() No value associated with key: '%s'", KEY_CONFIGNAMEESCAPED);
	if (!g_smQueryValues.GetString(KEY_MAP, sMap, sizeof(sMap))) LogError("logDBUsage() No value associated with key: '%s'", KEY_MAP);
	if (!g_smQueryValues.GetString(KEY_LOADERSTEAM64, sSteamID_Loader, sizeof(sSteamID_Loader))) LogError("logDBUsage() No value associated with key: '%s'", KEY_LOADERSTEAM64);
	if (!g_smQueryValues.GetString(KEY_OWNERSTEAM64ID, sSteamID_Owner, sizeof(sSteamID_Owner))) LogError("logDBUsage() No value associated with key: '%s'", KEY_OWNERSTEAM64ID);
	if (!g_smQueryValues.GetString(KEY_OWNERNAMEESCAPED, sEscapedOwnerName, sizeof(sEscapedOwnerName))) LogError("logDBUsage() No value associated with key: '%s'", KEY_OWNERNAMEESCAPED);
	if (!g_smQueryValues.GetValue(KEY_USERID, userid)) LogError("logDBUsage() No value associated with key: '%s'", KEY_USERID);
	if (!g_smQueryValues.GetValue(KEY_GAS, gas)) LogError("logDBUsage() No value associated with key: '%s'", KEY_GAS);
	if (!g_smQueryValues.GetValue(KEY_PROPANE, propane)) LogError("logDBUsage() No value associated with key: '%s'", KEY_PROPANE);
	if (!g_smQueryValues.GetValue(KEY_FIREWORKS, fireworks)) LogError("logDBUsage() No value associated with key: '%s'", KEY_FIREWORKS);
	if (!g_smQueryValues.GetValue(KEY_SPECIALAMMO, specialAmmo)) LogError("logDBUsage() No value associated with key: '%s'", KEY_SPECIALAMMO);

	// get client's name and escape it
	int client = GetClientOfUserId(userid);
	char sName_Loader[64];
	GetClientName(client, sName_Loader, sizeof(sName_Loader));
	int size = 2 * strlen(sName_Loader) + 1;
	char[] sEscapedPlayerName_Loader = new char[size];
	g_hDatabase.Escape(sName_Loader, sEscapedPlayerName_Loader, size);

	// escape hostname
	size = 2 * strlen(g_sHostName) + 1;
	char[] sEscapedHostName = new char[size];
	g_hDatabase.Escape(g_sHostName, sEscapedHostName, size);

	int iActiveStatus = 1;
	if (StrEqual(sAction, ACTION_DELETE)) iActiveStatus = 0;

	//  id 	owner_name 	owner_steam64ID 	name_user_who_loaded_config 	steam64ID_user_who_loaded_config
	// 	action 	config_UniqueID 	config_name 	map 	server_name 	server_ip 	gas 	propane 	
	//fireworks 	specialAmmo
	char sQueryBuffer[MAX_QUERY_LENGTH];
	Format(sQueryBuffer, sizeof(sQueryBuffer), "INSERT INTO `%s` (\
			owner_name, \
			owner_steam64ID, \
			name_user_who_loaded_config, \
			steam64ID_user_who_loaded_config, \
			action, \
			config_UniqueID, \
			config_name, \
			is_config_active, \
			map, \
			server_name, \
			server_ip, \
			gas, \
			propane, \
			fireworks, \
			specialAmmo) \
			VALUES (\
			'%s', \
			'%s', \
			'%s', \
			'%s', \
			'%s', \
			'%s', \
			'%s', \
			'%i', \
			'%s', \
			'%s', \
			'%s', \
			'%i', \
			'%i', \
			'%i', \
			'%i'\
			);", g_sDBTableLog, sEscapedOwnerName, sSteamID_Owner, sEscapedPlayerName_Loader, sSteamID_Loader, sAction, sConfigID, sConfigNameEscaped, iActiveStatus, sMap, sEscapedHostName, sServerIP, gas, propane, fireworks, specialAmmo);
	g_hDatabase.Query(Query_LogDBUsage, sQueryBuffer);
	
	// Need to show inactive status for that config, update columns..
	if (StrEqual(sAction, ACTION_DELETE))
	{
		DataPack pack = new DataPack();
		pack.WriteString(sConfigID);
		CreateTimer(1.0, Timer_SetInactiveStatus, pack);
	}
}

public Action Timer_SetInactiveStatus(Handle timer, DataPack pack)
{
	pack.Reset();
	char sConfigID[64], sQuery[MAX_QUERY_LENGTH];
	pack.ReadString(sConfigID, sizeof(sConfigID));
	delete pack;

	Format(sQuery, sizeof(sQuery), "UPDATE `%s` SET `is_config_active` = '0' WHERE config_UniqueID = '%s';", g_sDBTableLog, sConfigID);
	g_hDatabase.Query(Query_UpdateActiveStatusColumn, sQuery);
}

public void Query_LogDBUsage(Database db, DBResultSet results, const char[] error, DataPack pack)
{
	if (results == null)
	{
		LogError("MySQL DB error: %s", error);
	}
}

public void Query_UpdateActiveStatusColumn(Database db, DBResultSet results, const char[] error, DataPack pack)
{
	if (results == null)
	{
		LogError("MySQL DB error: %s", error);
	}
}

void GrabHostName(any data)
{
	FindConVar("hostname").GetString(g_sHostName, sizeof(g_sHostName));
}
