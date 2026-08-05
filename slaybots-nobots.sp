#include <sdktools>

#pragma semicolon	1
#pragma newdecls required

#define TEAM_SURVIVOR	2

bool g_bRoundInProgress;

// Bots shove each other around while they're being slain. DEBRIS still collides
// with the world, just not with other players.
#define COLLISION_GROUP_DEBRIS	1
#define COLLISION_GROUP_PLAYER	5

int g_iOldCollisionGroup[MAXPLAYERS + 1];

public Plugin myinfo =
{
    name = "SlayBots",
    author = "khan",
    description = "Slays all the bots.",
    version = "1.0"
};

public void OnPluginStart()
{
	RegConsoleCmd("sm_nobots", TeleportBots);
	RegConsoleCmd("sm_nobot", TeleportBots);
	RegConsoleCmd("sm_nb", TeleportBots);
	RegConsoleCmd("sm_slaybots", Cmd_SlayBots);
	
	// update for GM group - only allow command when round not in progress
	HookEvent("survival_round_start", Event_OnSurvivalStart);
	HookEvent("round_end", Event_OnRoundEnd);
}

public Action Cmd_SlayBots(int client, int args)
{	
	if (!client || GetClientTeam(client) != TEAM_SURVIVOR) { return Plugin_Handled; }
		
	if (g_bRoundInProgress)
	{
		PrintToChat(client, "[SM] Can't use this while a round is in progress");
		return Plugin_Handled;
	}
	
	FreezeBots();
	CreateTimer(0.3, Timer_SlayFrozenBots, _, TIMER_FLAG_NO_MAPCHANGE);

	return Plugin_Handled;
}

//
// A bot that dies mid-stride hands its own velocity to whatever it drops, which
// throws kit/pills across the room. Stop them dead first, kill them a moment later.
//
void FreezeBots()
{
	float fStill[3];

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || !IsFakeClient(i) || GetClientTeam(i) != TEAM_SURVIVOR || !IsPlayerAlive(i))
			continue;

		TeleportEntity(i, NULL_VECTOR, NULL_VECTOR, fStill);
		SetEntityMoveType(i, MOVETYPE_NONE);

		// Non-solid only now - the teleport above deliberately lets them collide
		// for 1.5s so they spread out first.
		if (g_iOldCollisionGroup[i] == 0)
		{
			g_iOldCollisionGroup[i] = GetEntProp(i, Prop_Send, "m_CollisionGroup");
		}
		SetEntProp(i, Prop_Send, "m_CollisionGroup", COLLISION_GROUP_DEBRIS);
	}
}

public Action Timer_SlayFrozenBots(Handle timer)
{
	float fStill[3];

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || !IsFakeClient(i) || GetClientTeam(i) != TEAM_SURVIVOR || !IsPlayerAlive(i))
			continue;

		TeleportEntity(i, NULL_VECTOR, NULL_VECTOR, fStill);
		ForcePlayerSuicide(i);

		// Never leave a frozen movetype or a non-solid bot behind - they can be
		// rescued later.
		SetEntityMoveType(i, MOVETYPE_WALK);

		int group = g_iOldCollisionGroup[i];
		if (group <= 0)
		{
			group = COLLISION_GROUP_PLAYER;
		}
		SetEntProp(i, Prop_Send, "m_CollisionGroup", group);
		g_iOldCollisionGroup[i] = 0;
	}

	return Plugin_Stop;
}

public void OnClientDisconnect(int client)
{
	g_iOldCollisionGroup[client] = 0;
}

public Action TeleportBots(int client, int args)
{
	if (!client || GetClientTeam(client) != TEAM_SURVIVOR) { return Plugin_Handled; }
		
	if (g_bRoundInProgress)
	{
		PrintToChat(client, "[SM] Can't use this while a round is in progress");
		return Plugin_Handled;
	}
	
	bool OnGround = false;
	if (GetEntityFlags(client) & FL_ONGROUND)
		OnGround = true;
	
	if (!OnGround)
	{
		PrintToChat(client, "[SM] You must be on the ground.");
		return Plugin_Handled;
	}
	
	float vec[3];
	GetClientAbsOrigin(client, vec);
	
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))continue;

		// Check if this is a bot survivor
		if (IsPlayerAlive(i) && IsFakeClient(i) && GetClientTeam(i) == TEAM_SURVIVOR)
			TeleportEntity(i, vec, NULL_VECTOR, NULL_VECTOR);
	}

	// Give the bots a chance to spread out a bit
	CreateTimer(1.5, Timer_SlayTeleBots, _, TIMER_FLAG_NO_MAPCHANGE);

	return Plugin_Handled;
}

public Action Timer_SlayTeleBots(Handle timer)
{
	// Stop them where they've spread out to, then kill them standing still.
	FreezeBots();
	CreateTimer(0.3, Timer_SlayFrozenBots, _, TIMER_FLAG_NO_MAPCHANGE);

	return Plugin_Stop;
}

public Action Event_OnSurvivalStart(Event event, const char[] name, bool dontBroadcast)
{
	g_bRoundInProgress = true;
}

public Action Event_OnRoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	g_bRoundInProgress = false;
}

public void OnMapStart()
{
	g_bRoundInProgress = false;
}