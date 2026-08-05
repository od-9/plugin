#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

// Provided by AutoSetup. Optional - slaysafe works fine without it.
native bool AutoSetup_MoveToWatchSpot(int client);

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	MarkNativeAsOptional("AutoSetup_MoveToWatchSpot");
	return APLRes_Success;
}

#define DEBUG 0

#define KEYVALUE_TITLE	"slaysafe"
#define CFG_PATH		"data/SlaySafeCoordinates.cfg"

// Auto slay: remembers one location per map and runs it on round start.
#define KEYVALUE_AUTO_TITLE	"slaysafe_auto"
#define AUTO_CFG_PATH		"data/SlaySafeAuto.cfg"
#define AUTO_MENU_ITEM		"__auto"
#define AUTO_MENU_OFF		"__off"
#define SAVE_MENU_ITEM		"__save"
#define DEL_MENU_ITEM		"__del"

ArrayList g_hArray_ConfigIDs;
char g_sConfigPath[PLATFORM_MAX_PATH];

char g_sAutoConfigPath[PLATFORM_MAX_PATH];
char g_sAutoSlayConfig[8];		// config ID for the current map, empty = off
ConVar g_cvAutoDelay;

// Every bot lands on the same coordinate, so they shove each other apart unless we
// make them non-solid first. DEBRIS still collides with the world, just not players.
#define COLLISION_GROUP_DEBRIS	1
#define COLLISION_GROUP_PLAYER	5

int g_iOldCollisionGroup[MAXPLAYERS + 1];

// Naming a new location: we grab the position when they pick the menu item, then
// wait for them to type the name in chat.
bool g_bAwaitingName[MAXPLAYERS + 1];
float g_fPendingPos[MAXPLAYERS + 1][3];

enum struct enum_Config {
	char sName[64];
	float slay[3];

	void clearSettings()
	{
		this.sName = "";
		for (int i = 0; i < 3; i++)
		{
			this.slay[i] = 0.0;
		}
	}
}

enum_Config g_Config;

public Plugin myinfo = {
	name		= "slaysafe",
	author		= "dustin",
	description = "slay bots in specified areas",
	version		= "1.0",
	url			= ""
};

/* TODO
	
	make sure global enum struct won't get reset if multiple people using menu
		for some reason.
*/

public void OnPluginStart()
{
	g_hArray_ConfigIDs = new ArrayList(ByteCountToCells(8));
	BuildPath(Path_SM, g_sConfigPath, sizeof(g_sConfigPath), CFG_PATH);
	BuildPath(Path_SM, g_sAutoConfigPath, sizeof(g_sAutoConfigPath), AUTO_CFG_PATH);

	//
	// The delay has to leave room for the other round start plugins to finish.
	// AutoSetup hands bots their weapons ~1s in, and GasConfig runs its gas can
	// routine at ~1s using a *bot* as the carrier - slaying that bot out from under
	// it is what leaves kit/pills stuck to a body.
	//
	g_cvAutoDelay = CreateConVar("slaysafe_auto_delay", "3.0", "Seconds after round start before auto slay runs. Must stay long enough for AutoSetup and GasConfig to finish.", _, true, 0.5, true, 30.0);

	RegConsoleCmd("sm_slaysafe", Command_Slaysafe);

	AddCommandListener(Command_SayHook, "say");
	AddCommandListener(Command_SayHook, "say_team");

	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);

	AutoExecConfig(true, "slaysafe");
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	if (g_sAutoSlayConfig[0] == '\0' || !IsSurvival())
	{
		return;
	}

	CreateTimer(g_cvAutoDelay.FloatValue, Timer_AutoSlay, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_AutoSlay(Handle timer)
{
	// Re-check everything: the round may have been started, or someone may have
	// turned auto slay off, during the delay.
	if (g_sAutoSlayConfig[0] == '\0' || !IsSurvival() || SurvivalRoundInProgress() || !AtLeastOneSurvivorBot())
	{
		return Plugin_Stop;
	}

	if (PopulateMenuIDs(0, g_sAutoSlayConfig) != -1)
	{
		slaySurvivorBots(g_Config.slay);
	}

	return Plugin_Stop;
}

public Action Command_Slaysafe(int client, int args)
{
	if (client < 1)
	{
		return Plugin_Handled;
	}

	// "!slaysafe save <name>" saves where you're standing under a name of your
	// choosing. Saving doesn't need bots alive, so it skips IsCommandAllowed().
	if (args >= 1)
	{
		char sArg[16];
		GetCmdArg(1, sArg, sizeof(sArg));

		if (StrEqual(sArg, "save", false))
		{
			char sName[64];
			if (args >= 2)
			{
				GetCmdArgString(sName, sizeof(sName));
				ReplaceStringEx(sName, sizeof(sName), sArg, "");
				TrimString(sName);
			}

			SaveCurrentPosition(client, sName);
			return Plugin_Handled;
		}

		PrintToChat(client, "[SM] Usage: !slaysafe            - open the menu");
		PrintToChat(client, "[SM]        !slaysafe save <name> - save your position");
		return Plugin_Handled;
	}

	if (IsCommandAllowed(client))
	{
		drawmainmenu(client);
	}
	return Plugin_Handled;
}

bool IsCommandAllowed(int client)
{
	if (IsSurvival() == false)
	{
		PrintToChat(client, "[SM] Command only available in survival mode.");
		return false;
	}

	if (SurvivalRoundInProgress())
	{
		PrintToChat(client, "[SM] Cannot use while round is in progress.");
		return false;
	}

	// Deliberately no "are any bots alive" check - the menu is still useful with
	// them dead, for saving/deleting spots and setting auto slay. Slaying with no
	// bots left simply does nothing.
	return true;
}

bool IsSurvival()
{
	char GameName[16];
	GetConVarString(FindConVar("mp_gamemode"), GameName, sizeof(GameName));
	return StrContains(GameName, "survival", false) != -1;
}

bool SurvivalRoundInProgress()
{
	return GameRules_GetPropFloat("m_flRoundStartTime") > 0.0 && GameRules_GetPropFloat("m_flRoundEndTime") == 0.0;
}

public Action Command_SayHook(int client, const char[] command, int argc)
{
	if (client < 1 || !g_bAwaitingName[client])
	{
		return Plugin_Continue;
	}

	char sText[64];
	GetCmdArgString(sText, sizeof(sText));
	StripQuotes(sText);
	TrimString(sText);

	// Let them run another command instead - treat it as backing out.
	if (sText[0] == '!' || sText[0] == '/')
	{
		g_bAwaitingName[client] = false;
		PrintToChat(client, "[SM] Naming cancelled.");
		return Plugin_Continue;
	}

	g_bAwaitingName[client] = false;

	if (sText[0] == '\0' || StrEqual(sText, "cancel", false))
	{
		PrintToChat(client, "[SM] Naming cancelled.");
	}
	else
	{
		SaveLocationAt(client, g_fPendingPos[client], sText);
	}

	// Swallow the message so the name doesn't show up as chat
	return Plugin_Handled;
}

bool AtLeastOneSurvivorBot()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i)) continue;
		if (IsFakeClient(i) && GetClientTeam(i) == 2 && IsPlayerAlive(i))
		{
			return true;
		}
	}
	return false;
}

public void OnConfigsExecuted()
{
	PopulateMenuIDs(0, "", true);
	LoadAutoSlayConfig();
}

/**************************************************
 * Auto slay setting (one location per map)
***************************************************/

void LoadAutoSlayConfig()
{
	g_sAutoSlayConfig = "";

	KeyValues kv = new KeyValues(KEYVALUE_AUTO_TITLE);

	if (kv.ImportFromFile(g_sAutoConfigPath))
	{
		char sMap[42];
		GetCurrentMap(sMap, sizeof(sMap));

		if (kv.JumpToKey(sMap, false))
		{
			kv.GetString("config", g_sAutoSlayConfig, sizeof(g_sAutoSlayConfig));
		}
	}

	delete kv;
}

void SaveAutoSlayConfig(const char[] sConfig)
{
	strcopy(g_sAutoSlayConfig, sizeof(g_sAutoSlayConfig), sConfig);

	KeyValues kv = new KeyValues(KEYVALUE_AUTO_TITLE);
	kv.ImportFromFile(g_sAutoConfigPath);	// fine if it doesn't exist yet
	kv_goToTop(kv);

	char sMap[42];
	GetCurrentMap(sMap, sizeof(sMap));

	if (kv.JumpToKey(sMap, true))
	{
		kv.SetString("config", sConfig);
	}

	kv_goToTop(kv);
	kv.ExportToFile(g_sAutoConfigPath);
	delete kv;
}

// Display name of the currently selected auto slay location, or "Off".
void GetAutoSlayLabel(char[] sBuffer, int maxlength)
{
	if (g_sAutoSlayConfig[0] != '\0' && PopulateMenuIDs(0, g_sAutoSlayConfig) != -1)
	{
		Format(sBuffer, maxlength, "Auto slay on round start: %s", g_Config.sName);
	}
	else
	{
		Format(sBuffer, maxlength, "Auto slay on round start: Off");
	}
}

/**************************************************
 * Menu items
***************************************************/

void drawmainmenu(int client)
{
	Menu hmenu = new Menu(MainMenuHandler);
	hmenu.SetTitle("Choose slay location");

	char sMap[16];
	GetCurrentMap(sMap, sizeof(sMap));

	char sConfig[8];
	for (int i = 0; i < g_hArray_ConfigIDs.Length; i++)
	{
		g_hArray_ConfigIDs.GetString(i, sConfig, sizeof(sConfig));
		if (PopulateMenuIDs(client, sConfig) != -1)
		{
			hmenu.AddItem(sConfig, g_Config.sName);
		}
		else
		{
			delete hmenu;
			return;
		}
	}

	char sAutoLabel[96];
	GetAutoSlayLabel(sAutoLabel, sizeof(sAutoLabel));
	hmenu.AddItem(AUTO_MENU_ITEM, sAutoLabel);

	hmenu.AddItem(SAVE_MENU_ITEM, "Save my current position as a location");
	hmenu.AddItem(DEL_MENU_ITEM, "Delete a location");

	hmenu.Display(client, MENU_TIME_FOREVER);
}

public int MainMenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char sMenuItem[32];
			menu.GetItem(param2, sMenuItem, sizeof(sMenuItem));

			// These only change saved settings - no need for bots to be alive.
			if (StrEqual(sMenuItem, AUTO_MENU_ITEM))
			{
				drawautomenu(param1);
			}
			else if (StrEqual(sMenuItem, SAVE_MENU_ITEM))
			{
				// Menu closes so they can see chat while typing the name
				PromptForLocationName(param1);
			}
			else if (StrEqual(sMenuItem, DEL_MENU_ITEM))
			{
				drawdeletemenu(param1);
			}
			// in case they left menu open when survival round started.
			else if (IsCommandAllowed(param1))
			{
				SlaySurvivorBots(param1, sMenuItem);
			}

		}

		case MenuAction_Cancel:
		{
			if (param2 == MenuCancel_ExitBack)
			{
				drawmainmenu(param1);
			}
		}
		
		case MenuAction_End:
			delete menu;
	}
}

void drawautomenu(int client)
{
	Menu hmenu = new Menu(AutoMenuHandler);
	hmenu.SetTitle("Auto slay on round start");
	hmenu.ExitBackButton = true;

	hmenu.AddItem(AUTO_MENU_OFF, (g_sAutoSlayConfig[0] == '\0') ? "Off (current)" : "Off");

	char sConfig[8];
	char sDisplay[96];
	for (int i = 0; i < g_hArray_ConfigIDs.Length; i++)
	{
		g_hArray_ConfigIDs.GetString(i, sConfig, sizeof(sConfig));

		if (PopulateMenuIDs(client, sConfig) == -1)
		{
			delete hmenu;
			return;
		}

		if (StrEqual(sConfig, g_sAutoSlayConfig))
		{
			Format(sDisplay, sizeof(sDisplay), "%s (current)", g_Config.sName);
		}
		else
		{
			strcopy(sDisplay, sizeof(sDisplay), g_Config.sName);
		}

		hmenu.AddItem(sConfig, sDisplay);
	}

	hmenu.Display(client, MENU_TIME_FOREVER);
}

public int AutoMenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char sMenuItem[32];
			menu.GetItem(param2, sMenuItem, sizeof(sMenuItem));

			if (StrEqual(sMenuItem, AUTO_MENU_OFF))
			{
				SaveAutoSlayConfig("");
				PrintToChatAll("\x01[SM] %N turned off \x04auto slay\x01.", param1);
			}
			else if (PopulateMenuIDs(param1, sMenuItem) != -1)
			{
				SaveAutoSlayConfig(sMenuItem);
				PrintToChatAll("\x01[SM] %N set \x04auto slay\x01 to: \x04%s\x01 (runs %.1fs after round start)", param1, g_Config.sName, g_cvAutoDelay.FloatValue);
			}

			drawmainmenu(param1);
		}

		case MenuAction_Cancel:
		{
			if (param2 == MenuCancel_ExitBack)
			{
				drawmainmenu(param1);
			}
		}

		case MenuAction_End:
			delete menu;
	}
}

/**************************************************
 * Saving / deleting locations
***************************************************/

//
// Saves where the caller is standing as a new location for this map. Written into
// the same coordinate file the hand-authored locations live in, so it shows up in
// the slay list straight away.
//
// Grabs the position now and asks for the name in chat, so you don't have to stand
// still while typing.
void PromptForLocationName(int client)
{
	if (client < 1 || !IsClientInGame(client))
	{
		return;
	}

	GetClientAbsOrigin(client, g_fPendingPos[client]);
	g_bAwaitingName[client] = true;

	PrintToChat(client, "[SM] Type a name for this location in chat, or \"cancel\".");
}

void SaveCurrentPosition(int client, const char[] sName)
{
	if (client < 1 || !IsClientInGame(client))
	{
		return;
	}

	float vPos[3];
	GetClientAbsOrigin(client, vPos);

	SaveLocationAt(client, vPos, sName);
}

void SaveLocationAt(int client, const float vPos[3], const char[] sName)
{
	if (client < 1 || !IsClientInGame(client))
	{
		return;
	}

	char sMap[42];
	GetCurrentMap(sMap, sizeof(sMap));

	KeyValues kv = new KeyValues(KEYVALUE_TITLE);
	kv.ImportFromFile(g_sConfigPath);	// fine if the file doesn't exist yet
	kv_goToTop(kv);

	if (!kv.JumpToKey(sMap, true))
	{
		delete kv;
		PrintToChat(client, "[SM] Couldn't write to the config file.");
		return;
	}

	char sNewID[8];
	NextFreeConfigID(kv, sNewID, sizeof(sNewID));

	if (!kv.JumpToKey(sNewID, true))
	{
		delete kv;
		PrintToChat(client, "[SM] Couldn't write to the config file.");
		return;
	}

	char sFinalName[64];
	if (sName[0] != '\0')
	{
		strcopy(sFinalName, sizeof(sFinalName), sName);
	}
	else
	{
		Format(sFinalName, sizeof(sFinalName), "Spot %s", sNewID);
	}

	kv.SetString("name", sFinalName);
	kv.SetVector("slay", vPos);

	kv_goToTop(kv);
	kv.ExportToFile(g_sConfigPath);
	delete kv;

	// Rebuild the ID list so the new entry appears in the menus
	PopulateMenuIDs(0, "", true);

	PrintToChat(client, "[SM] Saved location: %s", sFinalName);
}

// Section names are numeric. Find the highest and go one past it.
void NextFreeConfigID(KeyValues kv, char[] sBuffer, int maxlength)
{
	int highest = 0;

	if (kv.GotoFirstSubKey())
	{
		char sSection[8];
		do
		{
			kv.GetSectionName(sSection, sizeof(sSection));
			int id = StringToInt(sSection);
			if (id > highest)
			{
				highest = id;
			}
		}
		while (kv.GotoNextKey(false));

		kv.GoBack();
	}

	Format(sBuffer, maxlength, "%d", highest + 1);
}

void DeleteConfig(int client, const char[] sConfig)
{
	char sMap[42];
	GetCurrentMap(sMap, sizeof(sMap));

	KeyValues kv = new KeyValues(KEYVALUE_TITLE);

	if (!kv.ImportFromFile(g_sConfigPath) || !kv.JumpToKey(sMap, false))
	{
		delete kv;
		PrintToChat(client, "[SM] No locations to delete on this map.");
		return;
	}

	if (!kv.JumpToKey(sConfig, false))
	{
		delete kv;
		PrintToChat(client, "[SM] That location no longer exists.");
		return;
	}

	char sName[64];
	kv.GetString("name", sName, sizeof(sName));
	kv.GoBack();
	kv.DeleteKey(sConfig);

	kv_goToTop(kv);
	kv.ExportToFile(g_sConfigPath);
	delete kv;

	// Don't leave auto slay pointed at something that's gone
	if (StrEqual(sConfig, g_sAutoSlayConfig))
	{
		SaveAutoSlayConfig("");
	}

	PopulateMenuIDs(0, "", true);

	PrintToChat(client, "[SM] Deleted location: %s", sName);
}

void drawdeletemenu(int client)
{
	Menu hmenu = new Menu(DeleteMenuHandler);
	hmenu.SetTitle("Delete which location?");
	hmenu.ExitBackButton = true;

	char sConfig[8];
	for (int i = 0; i < g_hArray_ConfigIDs.Length; i++)
	{
		g_hArray_ConfigIDs.GetString(i, sConfig, sizeof(sConfig));

		if (PopulateMenuIDs(client, sConfig) == -1)
		{
			delete hmenu;
			return;
		}

		hmenu.AddItem(sConfig, g_Config.sName);
	}

	hmenu.Display(client, MENU_TIME_FOREVER);
}

public int DeleteMenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char sMenuItem[32];
			menu.GetItem(param2, sMenuItem, sizeof(sMenuItem));

			drawdeleteconfirmmenu(param1, sMenuItem);
		}

		case MenuAction_Cancel:
		{
			if (param2 == MenuCancel_ExitBack)
			{
				drawmainmenu(param1);
			}
		}

		case MenuAction_End:
			delete menu;
	}
}

// Deleting edits a file everyone shares, so make it a deliberate two-step.
void drawdeleteconfirmmenu(int client, const char[] sConfig)
{
	if (PopulateMenuIDs(client, sConfig) == -1)
	{
		return;
	}

	Menu hmenu = new Menu(DeleteConfirmMenuHandler);
	hmenu.SetTitle("Delete \"%s\"? This can't be undone.", g_Config.sName);
	hmenu.ExitBackButton = true;

	hmenu.AddItem(sConfig, "Yes, delete it");
	hmenu.AddItem(AUTO_MENU_OFF, "No, keep it");

	hmenu.Display(client, MENU_TIME_FOREVER);
}

public int DeleteConfirmMenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char sMenuItem[32];
			menu.GetItem(param2, sMenuItem, sizeof(sMenuItem));

			if (!StrEqual(sMenuItem, AUTO_MENU_OFF))
			{
				DeleteConfig(param1, sMenuItem);
			}

			drawmainmenu(param1);
		}

		case MenuAction_Cancel:
		{
			if (param2 == MenuCancel_ExitBack)
			{
				drawdeletemenu(param1);
			}
		}

		case MenuAction_End:
			delete menu;
	}
}

/**************************************************
 * Key Value Helpers
***************************************************/

void kv_goToTop(KeyValues kv)
{
	while (kv.NodesInStack() != 0)
		kv.GoBack();
}

int PopulateMenuIDs(int client = 0, const char[] sConfig = "1", bool bPopulateConfigIDs = false)
{
	if (bPopulateConfigIDs)
	{
		g_hArray_ConfigIDs.Clear();
	}

	KeyValues kv = new KeyValues(KEYVALUE_TITLE);
	if (kv.ImportFromFile(g_sConfigPath) == false)
	{
		delete kv;
		if (client) PrintToChat(client, "[SM] Error config file not found. Contact an admin.");
		LogError("Config file not found: %s", g_sConfigPath);
		return -1;
	}

	kv_goToTop(kv);
	char sMap[42];
	GetCurrentMap(sMap, sizeof(sMap));
	if (!kv.JumpToKey(sMap, false))
	{
		// could be custom map so don't log error
		LogMessage("No config found for current map (%s).", sMap);
		if (client) PrintToChat(client, "[SM] No configs exist for current map.");
		delete kv;
		return -1;
	}

	// populating menu IDs
	if (bPopulateConfigIDs)
	{
		if (!kv.GotoFirstSubKey())
		{
			delete kv;
			LogError("No sub keys found for map %s", sMap);
			if (client) PrintToChat(client, "[SM] Error No sub keys found for map '%s'. Contact an admin.", sMap);
			return -1;
		}

		char sSection[8];
		kv.GetSectionName(sSection, sizeof(sSection));
		g_hArray_ConfigIDs.PushString(sSection);

		while (kv.GotoNextKey(false))
		{
			kv.GetSectionName(sSection, sizeof(sSection));
			g_hArray_ConfigIDs.PushString(sSection);
		}
	}
	// looking up info on a specific config
	else
	{
		if (!kv.JumpToKey(sConfig, false))
		{
			delete kv;
			if (client) PrintToChat(client, "[SM] Error couldn't find config specified.");
			return -1;
		}

		g_Config.clearSettings();
		kv.GetString("name", g_Config.sName, sizeof(g_Config.sName));
		kv.GetVector("slay", g_Config.slay);
	}

	delete kv;
	return g_hArray_ConfigIDs.Length;
}

void SlaySurvivorBots(int client, const char[] sConfig)
{
	if (PopulateMenuIDs(client, sConfig))
	{
		slaySurvivorBots(g_Config.slay);
	}
}

//
// Bots are dropped onto the floor with no momentum and frozen in the same frame,
// then killed a moment later. Freezing immediately is what stops them shoving each
// other - they all land on the same coordinate, and L4D2 pushes overlapping
// survivors apart regardless of collision group. A bot that dies mid-shove also
// hands its velocity to whatever it drops, which throws kit/pills across the room.
//
void slaySurvivorBots(float fLocation[3])
{
	float fStill[3];
	float fGround[3];

	// Trace down once - freezing mid-air would leave them hanging if the configured
	// coordinate sits above the floor.
	SnapToGround(fLocation, fGround);

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || !IsFakeClient(i) || GetClientTeam(i) != 2 || !IsPlayerAlive(i))
			continue;

		SetBotNonSolid(i);

		TeleportEntity(i, fGround, NULL_VECTOR, fStill);
		SetEntityMoveType(i, MOVETYPE_NONE);

		#if !DEBUG
		CreateTimer(0.3, timer_forcesuicide, GetClientUserId(i));
		#endif
	}

	MovePlayersToWatchSpots();
}

//
// Anyone with a watch spot saved in !setup gets dropped on it as the bots go down,
// so you don't have to walk back to your spot every round. Provided by AutoSetup as
// an optional native - if that plugin isn't loaded, nothing happens.
//
void MovePlayersToWatchSpots()
{
	if (GetFeatureStatus(FeatureType_Native, "AutoSetup_MoveToWatchSpot") != FeatureStatus_Available)
	{
		return;
	}

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i) || GetClientTeam(i) != 2 || !IsPlayerAlive(i))
			continue;

		AutoSetup_MoveToWatchSpot(i);
	}
}

// Drops a point straight down onto the first solid world surface below it.
void SnapToGround(const float fPos[3], float fResult[3])
{
	float fEnd[3];
	fEnd[0] = fPos[0];
	fEnd[1] = fPos[1];
	fEnd[2] = fPos[2] - 200.0;

	Handle hTrace = TR_TraceRayFilterEx(fPos, fEnd, MASK_PLAYERSOLID, RayType_EndPoint, TraceFilter_IgnorePlayers);

	if (TR_DidHit(hTrace))
	{
		TR_GetEndPosition(fResult, hTrace);
	}
	else
	{
		fResult[0] = fPos[0];
		fResult[1] = fPos[1];
		fResult[2] = fPos[2];
	}

	delete hTrace;
}

public bool TraceFilter_IgnorePlayers(int entity, int contentsMask)
{
	return entity > MaxClients;
}

void SetBotNonSolid(int client)
{
	if (g_iOldCollisionGroup[client] == 0)
	{
		g_iOldCollisionGroup[client] = GetEntProp(client, Prop_Send, "m_CollisionGroup");
	}

	SetEntProp(client, Prop_Send, "m_CollisionGroup", COLLISION_GROUP_DEBRIS);
}

void RestoreBotCollision(int client)
{
	int group = g_iOldCollisionGroup[client];
	if (group <= 0)
	{
		group = COLLISION_GROUP_PLAYER;
	}

	SetEntProp(client, Prop_Send, "m_CollisionGroup", group);
	g_iOldCollisionGroup[client] = 0;
}

public void OnClientDisconnect(int client)
{
	g_iOldCollisionGroup[client] = 0;
	g_bAwaitingName[client] = false;
}

public Action timer_forcesuicide(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);

	if (client > 0 && IsClientInGame(client))
	{
		float fStill[3];
		TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, fStill);

		ForcePlayerSuicide(client);

		// Never leave a frozen movetype or a non-solid bot behind - they can be
		// rescued later.
		SetEntityMoveType(client, MOVETYPE_WALK);
		RestoreBotCollision(client);
	}

	return Plugin_Stop;
}

