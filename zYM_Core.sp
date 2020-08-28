#pragma semicolon 1
#include <sourcemod>                                      
#include <sdktools> 

//#define _DEBUG
#define VERSION "1.0" 
#define ZDIR "logs/demos/" 
#define zPORT GetConVarInt( FindConVar( "hostport" ) )

Database zDB;
new zSID = 0;
new zMID = 0;

// public cvar 
new Handle:ym_version;    // version
new Handle:ym_minplayers;    // convar for minimum human players required for recording 
new Handle:ym_enabled;     // should demos be recorded 
// cached values 
new zMinplayers;                 
new zEnabled;
// demo 
new bool:demo_active;        // is demo currently recording 
new demo_time;                // timestamp of demo start 
new String:demo_name[128];    // name of demo, ie "auto-server-030114-203000-cs_office" 
new Float:demo_active_time;    // last game time the game was confirmed to have people playing 
new Float:demo_start_time;    // game time when the demo was started 
new String:demo_path[128];    // path to "sm/data/demos" 

public Plugin myinfo = 
{
	name = "YM_Core",
	author = "dYoMa",
	description = "YM plugin",
	version = "1.0",
	url = "https://ym-csw.ru/"
};

//------------------------------------------------------------------------------------------------- 
public void OnPluginStart()
{
	//Hooks
	HookEvent("round_end", Event_RoundEnd, EventHookMode_Post);
	HookEvent("round_start", Event_RoundStart);
	HookEvent("player_team", OnPlayerTeam, EventHookMode_PostNoCopy); 


	RegConsoleCmd( "sm_demo", Command_demo );  
	RegConsoleCmd( "sm_start", Command_start );  
	RegConsoleCmd( "sm_stop", Command_stop );  
	ym_version = CreateConVar( "ym_version", VERSION, "YM Core Plugin Version", FCVAR_NOTIFY );
	SetConVarString( ym_version, VERSION ); 
	ym_minplayers = CreateConVar( "ym_minplayers", "2", "Number of human players required for automatic demo recording", FCVAR_NOTIFY ); 
	ym_enabled = CreateConVar( "ym_enabled", "1", "Enable YM Core plugin", FCVAR_NOTIFY ); 
	zMinplayers = GetConVarInt(ym_minplayers); 
	zEnabled = GetConVarInt(ym_minplayers); 
	AutoExecConfig(true, "YM_Core");

}                                    

//------------------------------------------------------------------------------------------------- 
public OnConVarChanged( Handle:cvar, const String:oldv[], const String:newv[] ) { 
    if( cvar == ym_minplayers ) { 
        zMinplayers = GetConVarInt( ym_minplayers ); 
    } else if( cvar == ym_enabled ) { 
        zEnabled = GetConVarInt( ym_enabled ); 
         
        if( zEnabled == 0 ) { 
            StopDemo(); 
        } else { 
            TryStartDemo(); 
        }
    } 
} 

//------------------------------------------------------------------------------------------------- 
public void OnMapStart()
{
	char error[255];
	if (SQL_CheckConfig("stats"))
	{
		zDB = SQL_Connect("stats", true, error, sizeof(error));
	} else {
		zDB = SQL_Connect("default", true, error, sizeof(error));
	}
	if (zDB == null)
	{
		LogError("[rank]Could not connect to database \"default\": %s", error);
		return;
	} else {
	SQL_FastQuery(zDB, "SET NAMES UTF8");  
	zSID = GetServerID();
	if (!zSID){
		return;
	}
//	delete zDB;
	}
}


//------------------------------------------------------------------------------------------------- 
stock int GetServerID()
{
	char query[255], error[255];
	DBResultSet rs;

	Format(query, sizeof(query), "SELECT `id` FROM `servers` WHERE ( `port` = '%d' )", zPORT);
#if defined _DEBUG
	PrintToServer("%s",query);
#endif
	if ((rs = SQL_Query(zDB, query)) == null)
	{
		SQL_GetError(zDB, error, sizeof(error));
		LogError("[YM_Core]GetServerID() query failed: %s", query);
		LogError("[YM_Core]Query error: %s", error);
		return 0;
	}
	while (rs.FetchRow())
	{
		zSID =  rs.FetchInt(0);
#if defined _DEBUG
		PrintToServer("PORT: %d, SID: %d",zPORT, zSID);
#endif
	}
	delete rs;
	return zSID;
}
 
//------------------------------------------------------------------------------------------------- 
stock int GetPlayerID(any client)
{
        new zStatsID = 0;
	char query[255], error[255];
	DBResultSet rs;
	decl String:bit[3][64];
	char steamId[64];
	GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId));
	ExplodeString(steamId, ":", bit, sizeof bit, sizeof bit[]);
	Format(query, sizeof(query), "SELECT `playerId` FROM `hlstats_PlayerUniqueIds` WHERE ( `uniqueId` = '%s:%s' ) and ( `game` = 'csgo_%d' )",bit[1],bit[2],gPort);
#if defined _DEBUG
	PrintToServer("%s",query);
#endif
	if ((rs = SQL_Query(zDB, query)) == null)
	{
		SQL_GetError(zDB, error, sizeof(error));
		LogError("[YM_Core]GetPlayerID() query failed: %s", query);
		LogError("[YM_Core]Query error: %s", error);
		return 0;
	}
	while (rs.FetchRow())
	{
		zStatsID =  rs.FetchInt(0);
#if defined _DEBUG
		PrintToServer("Client: %d, SteamID: %s,  StatsID: %d",client, steamId, zStatsID );
#endif
	}
	delete rs;
	return zStatsID;
}

//------------------------------------------------------------------------------------------------- 
public Action Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	return Plugin_Handled;
}

//------------------------------------------------------------------------------------------------- 
public Action Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	return Plugin_Handled;
}

//------------------------------------------------------------------------------------------------- 
public OnPlayerTeam( Handle:event, const String:name[], bool:dontBroadcast ) { 
    // this function is basically no load to the server since it blocks itself once the demo starts 
    // and the demo starts once a few people join the server 
    if( demo_active ) return; 
    if( !zEnabled ) return; 
    TryStartDemo(); 
} 

//------------------------------------------------------------------------------------------------- 
public OnMatchRestart( Handle:event, const String:name[], bool:db ) { 
    StopDemo(); 
} 

//------------------------------------------------------------------------------------------------- 
public OnMapEnd() { 
    StopDemo(); 
} 

//------------------------------------------------------------------------------------------------- 
StartDemo() { 
    if( demo_active ) return; 
    decl String:time[32], String:map[32]; 
    demo_time = GetTime(); 
    GetCurrentMap( map, sizeof(map) ); 
    { 
        ReplaceString( map, sizeof map, "\\", "/" ); 
        new pos = FindCharInString( map, '/', true ); 
        if( pos != -1 ) { 
            strcopy( map, sizeof map, map[pos+1] ); 
        } 
    } 
    decl String:date[64]; 
    FormatTime( date, sizeof date, "%m%d%y", demo_time ); 
    FormatTime( time, sizeof time, "%H%M%S", demo_time ); 
    Format( time, sizeof time, "%s-%s", date, time ); 
    Format( demo_name, sizeof(demo_name), "%d-%s-%s",zPORT, time, map ); 
    ServerCommand( "tv_record \"%s%s\"", demo_path, demo_name ); 
    demo_start_time = GetGameTime(); 
    demo_active = true; 
    PrintToChatAll( "Recording Demo... %s.dem", demo_name ); 
} 
  
//------------------------------------------------------------------------------------------------- 
StopDemo() { 
    if( !demo_active ) return; 
    ServerCommand("tv_stoprecord"); 
    demo_active = false; 
} 


//------------------------------------------------------------------------------------------------- 
stock int GetNumClients() { 
    new count = 0; 
    for( new i = 1; i <= MaxClients; i++ ) { 
        if( !IsClientInGame(i) ) continue; 
        if( IsFakeClient(i) ) continue; 
        if( GetClientTeam(i) < 2 ) continue; 
        count++; 
    } 
    return count; 
} 

//------------------------------------------------------------------------------------------------- 
bool:TryStartDemo() { 
    if( !zEnabled ) return false;  
    // if clients > minplayers, start demo (if not already started) and update active time 
    new active_clients = GetNumClients(); 
    if( active_clients >= zMinplayers ) {  
        StartDemo(); 
        demo_active_time = GetGameTime(); 
        return true; 
    } 
    return false; 
}

//------------------------------------------------------------------------------------------------- 
public Action:Command_demo( client, args ) { 
    if( !demo_active ) { 
        ReplyToCommand( client, "A demo is not currently being recorded." ); 
        return Plugin_Handled; 
    } 
    ReplyToCommand( client, "Currently recording: %s.dem", demo_name ); 
    return Plugin_Handled; 
}
//------------------------------------------------------------------------------------------------- 
public Action:Command_start( client, args ) { 
    if( demo_active ) { 
        ReplyToCommand( client, "Currently recording: %s.dem", demo_name ); 
        return Plugin_Handled; 
    } 
    StartDemo(); 
    ReplyToCommand( client, "Start recording: %s.dem", demo_name ); 
    return Plugin_Handled; 
}

public Action:Command_stop( client, args ) { 
    if( !demo_active ) { 
        ReplyToCommand( client, "A demo is not currently being recorded." ); 
        return Plugin_Handled; 
    } 
    StopDemo(); 
    ReplyToCommand( client, "Stop recording: %s.dem", demo_name ); 
    return Plugin_Handled; 
}
