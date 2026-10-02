#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <dhooks>
#include <left4dhooks>

Handle isTankActive;
bool hiddenTankPanel[MAXPLAYERS + 1];

// AI Tank suicide countdown state (per tank client)
float g_fStuckSuicide[MAXPLAYERS + 1];
float g_fStasisSuicide[MAXPLAYERS + 1];
float g_fLosSuicide[MAXPLAYERS + 1];
float g_fRawStuck[MAXPLAYERS + 1];
float g_fRawStasis[MAXPLAYERS + 1];
float g_fVisTime[MAXPLAYERS + 1];

// IntervalTimer layout: vtable (4 bytes) then float m_timestamp.
#define OFFSET_TANKATTACK_STUCK		0x486C
#define OFFSET_TANKATTACK_STASIS	0x4874

#define OFFSET_TANK_NEXTBOT			0x4040
#define VTBL_GET_VISION_INTERFACE	0xC8	// INextBot::GetVisionInterface
#define VTBL_GET_TIME_SINCE_VISIBLE	0xB4	// IVision::GetTimeSinceVisible

#define TEAM_SURVIVORS				2

ConVar g_cvStuckOffset;
ConVar g_cvStasisOffset;
ConVar g_cvNextBotOffset;
ConVar g_cvVtblGetVision;
ConVar g_cvVtblTimeSinceVisible;

ConVar g_cvStuckTime;
ConVar g_cvStasisTime;
ConVar g_cvVisTol;
ConVar g_cvFailsafe;

DynamicDetour g_hTankAttackUpdate;
Handle g_hGetVisionInterface;
Handle g_hGetTimeSinceVisible;

bool g_bHasAddrNatives;

public Plugin myinfo =
{
	name = "[L4D2] Tank Hud",
	author = "ConfoglTeam & Accelerator",
	description = "Displays AI Tank suicide countdowns.",
	version = "3.6",
	url = "https://github.com/accelerator74/sp-plugins"
};

public void OnPluginStart()
{
	HookEvent("round_start", Round_Event, EventHookMode_PostNoCopy);
	HookEvent("round_end", Round_Event, EventHookMode_PostNoCopy);
	HookEvent("tank_spawn", TankSpawn_Event);

	RegConsoleCmd("sm_tankhud", ToggleTankPanel_Cmd, "Toggles the tank panel visibility so other menus can be seen");
	RegConsoleCmd("sm_spechud", ToggleTankPanel_Cmd, "Toggles the tank panel visibility so other menus can be seen");

	g_cvStuckTime = FindConVar("tank_stuck_time_suicide");
	g_cvStasisTime = FindConVar("tank_stasis_time_suicide");
	g_cvVisTol = FindConVar("tank_visibility_tolerance_suicide");
	g_cvFailsafe = FindConVar("tank_stuck_failsafe");

	g_cvStuckOffset = CreateConVar("tank_hud_stuck_offset", "18540", "TankAttack + this = m_stuckTimer.m_timestamp", FCVAR_NONE, true, 0.0);
	g_cvStasisOffset = CreateConVar("tank_hud_stasis_offset", "18548", "TankAttack + this = m_stasisTimer.m_timestamp", FCVAR_NONE, true, 0.0);
	g_cvNextBotOffset = CreateConVar("tank_hud_nextbot_offset", "16448", "Tank + this = embedded INextBot subobject", FCVAR_NONE, true, 0.0);
	g_cvVtblGetVision = CreateConVar("tank_hud_vtbl_vision", "50", "INextBot vtable index of GetVisionInterface (0xC8 / 4)", FCVAR_NONE, true, 0.0);
	g_cvVtblTimeSinceVisible = CreateConVar("tank_hud_vtbl_sincevisible", "45", "IVision vtable index of GetTimeSinceVisible (0xB4 / 4)", FCVAR_NONE, true, 0.0);

	g_bHasAddrNatives =
		(GetFeatureStatus(FeatureType_Native, "L4D_GetEntityFromAddress") == FeatureStatus_Available) &&
		(GetFeatureStatus(FeatureType_Native, "L4D_GetClientFromAddress") == FeatureStatus_Available);

	SetupVisionCalls();
	SetupTankAttackHook();
}

public void OnPluginEnd()
{
	if (g_hTankAttackUpdate != null)
	{
		g_hTankAttackUpdate.Disable(Hook_Pre, OnTankAttackUpdate);
		delete g_hTankAttackUpdate;
	}

	if (g_hGetVisionInterface != null)
		delete g_hGetVisionInterface;

	if (g_hGetTimeSinceVisible != null)
		delete g_hGetTimeSinceVisible;
}

void SetupVisionCalls()
{
	StartPrepSDKCall(SDKCall_Raw);
	PrepSDKCall_SetVirtual(g_cvVtblGetVision.IntValue);
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	g_hGetVisionInterface = EndPrepSDKCall();

	StartPrepSDKCall(SDKCall_Raw);
	PrepSDKCall_SetVirtual(g_cvVtblTimeSinceVisible.IntValue);
	PrepSDKCall_SetReturnInfo(SDKType_Float, SDKPass_ByValue);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	g_hGetTimeSinceVisible = EndPrepSDKCall();

	if (g_hGetVisionInterface == null || g_hGetTimeSinceVisible == null)
		LogError("Could not prepare IVision SDKCalls; LOS suicide countdown disabled");
}

void SetupTankAttackHook()
{
	GameData gd = LoadGameConfigFile("tank_hud");
	if (gd == null)
	{
		LogError("Failed to load gamedata/tank_hud.txt");
		return;
	}

	Address addr = gd.GetMemSig("TankAttack::Update");
	delete gd;

	if (addr == Address_Null)
	{
		LogError("Could not find TankAttack::Update signature");
		return;
	}

	g_hTankAttackUpdate = new DynamicDetour(addr, CallConv_THISCALL, ReturnType_Void, ThisPointer_Address);
	if (g_hTankAttackUpdate == null)
	{
		LogError("DynamicDetour TankAttack::Update failed");
		return;
	}

	g_hTankAttackUpdate.AddParam(HookParamType_Int);   // hidden ActionResult* ret
	g_hTankAttackUpdate.AddParam(HookParamType_Int);   // Tank* me
	g_hTankAttackUpdate.AddParam(HookParamType_Float); // float interval

	if (!g_hTankAttackUpdate.Enable(Hook_Pre, OnTankAttackUpdate))
		LogError("Failed to enable TankAttack::Update detour");
}

public MRESReturn OnTankAttackUpdate(Address pThis, DHookParam hParams)
{
	if (pThis == Address_Null)
		return MRES_Ignored;

	Address me = view_as<Address>(DHookGetParam(hParams, 2));
	int tank = ResolveTankClient(me);

	if (tank < 1 || tank > MaxClients)
		return MRES_Ignored;

	g_fRawStuck[tank] = ReadTimerTimestamp(pThis, g_cvStuckOffset.IntValue);
	g_fRawStasis[tank] = ReadTimerTimestamp(pThis, g_cvStasisOffset.IntValue);

	g_fStuckSuicide[tank] = CountdownFrom(g_fRawStuck[tank], g_cvStuckTime.FloatValue);
	g_fStasisSuicide[tank] = CountdownFrom(g_fRawStasis[tank], g_cvStasisTime.FloatValue);

	UpdateLosCountdown(me, tank);

	return MRES_Ignored;
}

void UpdateLosCountdown(Address me, int tank)
{
	g_fVisTime[tank] = -1.0;
	g_fLosSuicide[tank] = 0.0;

	if (g_hGetVisionInterface == null || g_hGetTimeSinceVisible == null)
		return;

	Address pNextBot = me + view_as<Address>(g_cvNextBotOffset.IntValue);
	Address pVision = view_as<Address>(SDKCall(g_hGetVisionInterface, pNextBot));
	if (pVision == Address_Null)
		return;

	float visTime = SDKCall(g_hGetTimeSinceVisible, pVision, TEAM_SURVIVORS);
	g_fVisTime[tank] = visTime;

	if (visTime >= 999999.0 || visTime < 0.1)
		return;

	float remaining = g_cvVisTol.FloatValue - visTime;
	g_fLosSuicide[tank] = remaining > 0.0 ? remaining : 0.0;
}

int ResolveTankClient(Address me)
{
	if (g_bHasAddrNatives && me != Address_Null)
	{
		int client = L4D_GetEntityFromAddress(me);
		if (client > 0 && client <= MaxClients && IsClientInGame(client) && IsPlayerAlive(client) && GetZombieClass(client) == 8)
			return client;

		client = L4D_GetClientFromAddress(me);
		if (client > 0 && client <= MaxClients && IsClientInGame(client) && IsPlayerAlive(client) && GetZombieClass(client) == 8)
			return client;
	}

	// Fallback: find the currently alive AI tank.
	// We use IsPlayerAlive instead of GetTankAlive to avoid false negatives 
	// caused by m_isGhost during the brief spawn transition period.
	int found = 0;
	int aliveCount = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && IsFakeClient(i) && GetClientTeam(i) == 3 && GetZombieClass(i) == 8)
		{
			if (IsPlayerAlive(i))
			{
				found = i;
				aliveCount++;
			}
		}
	}

	// Only return if we found exactly one alive tank to avoid ambiguity
	return (aliveCount == 1) ? found : 0;
}

float ReadTimerTimestamp(Address pThis, int timestampOff)
{
	Address pTimestamp = pThis + view_as<Address>(timestampOff);
	return view_as<float>(LoadFromAddress(pTimestamp, NumberType_Int32));
}

float CountdownFrom(float timestamp, float suicideTime)
{
	if (timestamp <= 0.0)
		return 0.0;

	float remaining = suicideTime - (GetGameTime() - timestamp);
	return remaining > 0.0 ? remaining : 0.0;
}

public void Round_Event(Event event, const char[] name, bool dontBroadcast)
{
	delete isTankActive;
	ClearCountdowns();
}

public void TankSpawn_Event(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client > 0 && client <= MaxClients)
	{
		ResetTankState(client);
	}

	if (isTankActive == null)
	{
		for (int i = 1; i <= MaxClients; i++)
			hiddenTankPanel[i] = false;

		isTankActive = CreateTimer(0.5, MenuRefresh_Timer, _, TIMER_REPEAT);
	}
}

public void L4D_OnReplaceTank(int tank, int newtank)
{
	if (tank != newtank)
	{
		// Transfer countdown states to the new tank client so tracking continues seamlessly
		g_fStuckSuicide[newtank] = g_fStuckSuicide[tank];
		g_fStasisSuicide[newtank] = g_fStasisSuicide[tank];
		g_fLosSuicide[newtank] = g_fLosSuicide[tank];
		g_fRawStuck[newtank] = g_fRawStuck[tank];
		g_fRawStasis[newtank] = g_fRawStasis[tank];
		g_fVisTime[newtank] = g_fVisTime[tank];

		ResetTankState(tank);
	}
}

public void OnClientDisconnect(int client)
{
	hiddenTankPanel[client] = false;
	ResetTankState(client);
}

void ResetTankState(int client)
{
	g_fStuckSuicide[client] = 0.0;
	g_fStasisSuicide[client] = 0.0;
	g_fLosSuicide[client] = 0.0;
	g_fRawStuck[client] = 0.0;
	g_fRawStasis[client] = 0.0;
	g_fVisTime[client] = 0.0;
}

void ClearCountdowns()
{
	for (int i = 1; i <= MaxClients; i++)
		ResetTankState(i);
}

public Action MenuRefresh_Timer(Handle timer)
{
	int iTankCount;
	int iTankClients[MAXPLAYERS + 1];

	// Dynamically gather ALL currently alive tanks (supports 2+ tanks naturally)
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && GetClientTeam(i) == 3 && GetZombieClass(i) == 8 && IsPlayerAlive(i) && !GetEntProp(i, Prop_Send, "m_isGhost"))
		{
			iTankClients[iTankCount] = i;
			iTankCount++;
		}
	}

	if (iTankCount < 1)
	{
		isTankActive = null;
		return Plugin_Stop;
	}

	char buffer[128];
	Panel menuPanel = new Panel();

	menuPanel.SetTitle("Tank HUD");
	menuPanel.DrawText("\n");

	for (int j = 0; j < iTankCount; j++)
	{
		int tank = iTankClients[j];
		
		FormatEx(buffer, sizeof(buffer), "Tank %d", j + 1);
		menuPanel.DrawText(buffer);

		if (IsFakeClient(tank))
		{
			DrawSuicideLines(menuPanel, tank, buffer, sizeof(buffer));
		}
		else
		{
			menuPanel.DrawText("Suicide: N/A (Human)");
		}

		menuPanel.DrawText("\n");
	}

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i) &&
			(GetClientTeam(i) == 1 || GetClientTeam(i) == 2) &&
			!hiddenTankPanel[i])
		{
			menuPanel.Send(i, DummyHandler, 1);
		}
	}

	delete menuPanel;
	return Plugin_Continue;
}

void DrawSuicideLines(Panel menuPanel, int tank, char[] buffer, int maxlen)
{
	bool drew = false;

	if (g_fLosSuicide[tank] > 0.0)
	{
		FormatEx(buffer, maxlen, "Suicide: %.1fs (LOS)", g_fLosSuicide[tank]);
		menuPanel.DrawText(buffer);
		drew = true;
	}

	if (g_fStuckSuicide[tank] > 0.0)
	{
		FormatEx(buffer, maxlen, "Suicide: %.1fs (stuck)", g_fStuckSuicide[tank]);
		menuPanel.DrawText(buffer);
		drew = true;
	}
	else if (g_fRawStuck[tank] > 0.0)
	{
		FormatEx(buffer, maxlen, "Suicide: imminent (stuck %.0fs)", GetGameTime() - g_fRawStuck[tank]);
		menuPanel.DrawText(buffer);
		drew = true;
	}

	if (g_fStasisSuicide[tank] > 0.0)
	{
		FormatEx(buffer, maxlen, "Suicide: %.1fs (stasis)", g_fStasisSuicide[tank]);
		menuPanel.DrawText(buffer);
		drew = true;
	}

	if (!drew)
	{
		FormatEx(buffer, maxlen, "Suicide: --");
		menuPanel.DrawText(buffer);
	}
}

public int DummyHandler(Menu menu, MenuAction action, int param1, int param2)
{
	return 1;
}

public Action ToggleTankPanel_Cmd(int client, int args)
{
	if (client == 0)
	{
		PrintToServer("[Tank HUD] This command can only be used by a player.");
		return Plugin_Handled;
	}

	if (!hiddenTankPanel[client])
	{
		hiddenTankPanel[client] = true;
		PrintToChat(client, "\x05Tank HUD disabled.");
	}
	else
	{
		hiddenTankPanel[client] = false;
		PrintToChat(client, "\x05Tank HUD enabled.");

		if (isTankActive == null)
		{
			for (int i = 1; i <= MaxClients; i++)
			{
				if (IsClientInGame(i) && GetClientTeam(i) == 3 && GetZombieClass(i) == 8 && IsPlayerAlive(i))
				{
					isTankActive = CreateTimer(0.5, MenuRefresh_Timer, _, TIMER_REPEAT);
					break;
				}
			}
		}
	}

	return Plugin_Handled;
}

stock int GetZombieClass(int client) { return GetEntProp(client, Prop_Send, "m_zombieClass"); }