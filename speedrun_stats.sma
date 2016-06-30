// Credits: R3X
#include <amxmodx>
#include <amxmisc>
#include <engine>
#include <fakemeta>
#include <reapi>
#include <geoip>
#include <sqlx>

#if AMXX_VERSION_NUM < 183
#include <colorchat>
#endif

#define PLUGIN "Speedrun: Stats"
#define VERSION "0.2"
#define AUTHOR "Mistrick"

#pragma semicolon 1

#define FINISH_CLASSNAME "SR_FINISH"
#define BOXLIFE 3

enum _:PlayerData
{
	m_bConnected,
	m_bAuthorized,
	m_bTimerStarted,
	m_bFinished,
	m_iPlayerIndex,
	Float:m_fStartRun
};
enum _:Categories
{
	Cat_100fps,
	Cat_200fps,
	Cat_250fps,
	Cat_333fps,
	Cat_500fps,
	Cat_FastRun,
	Cat_CrazySpeed
};
enum _:Cvars
{
	SQL_HOST,
	SQL_USER,
	SQL_PASSWORD,
	SQL_DATABASE
};

new const PREFIX[] = "^4[Speedrun]";

new const g_szCategory[][] = 
{
	"[100 FPS]", "[200 FPS]", "[250 FPS]", "[333 FPS]", "[500 FPS]", "[Fastrun]", "[Crazy Speed]"
};

new g_pCvars[Cvars];
new Handle:g_hTuple, g_szQuery[512];
new g_szMapName[32];
new g_iMapIndex;
new g_ePlayerInfo[33][PlayerData];
new g_iBestTime[33][Categories];
new g_iFinishEnt;
new g_iSprite;
new g_szMotd[1536];
new g_iBestTimeofMap[Categories];
new g_fwFinished;
new g_iReturn;

native get_user_category(id);
forward SR_PlayerOnStart(id);

public plugin_init()
{
	register_plugin(PLUGIN, VERSION, AUTHOR);
	
	g_pCvars[SQL_HOST] = register_cvar("speedrun_host", "127.0.0.1");
	g_pCvars[SQL_USER] = register_cvar("speedrun_user", "root");
	g_pCvars[SQL_PASSWORD] = register_cvar("speedrun_password", "root");
	g_pCvars[SQL_DATABASE] = register_cvar("speedrun_database", "speedrun");
	
	register_clcmd("setfinish", "Command_SetFinish", ADMIN_CFG);
	register_clcmd("say /rank", "Command_Rank");
	register_clcmd("say /top15", "Command_Top15");
	register_clcmd("say /update", "Command_Update");
	
	RegisterHookChain(RG_CBasePlayer_Jump, "HC_CheckStartTimer", false);
	RegisterHookChain(RG_CBasePlayer_Duck, "HC_CheckStartTimer", false);
	RegisterHookChain(RG_CBasePlayer_Spawn, "HC_CBasePlayer_Spawn_Post", true);
	
	register_think(FINISH_CLASSNAME, "Think_DrawFinishBox");
	register_touch(FINISH_CLASSNAME, "player", "Engine_TouchFinish");
	
	g_fwFinished = CreateMultiForward("SR_PlayerFinishedMap", ET_IGNORE, FP_CELL, FP_CELL, FP_CELL);
	
	CreateTimer();
}
public plugin_cfg()
{
	set_task(0.5, "DB_Init");
}
public plugin_precache()
{
	g_iSprite = precache_model("sprites/white.spr");
}
public Command_SetFinish(id, level, cid)
{
	if(!cmd_access(id, level, cid, 1)) return PLUGIN_HANDLED;
	
	g_ePlayerInfo[id][m_bFinished] = true;
	
	new Float:fOrigin[3]; get_entvar(id, var_origin, fOrigin);
	CreateFinish(fOrigin);
	SaveFinishOrigin();
	
	return PLUGIN_HANDLED;
}
SaveFinishOrigin()
{
	if(is_valid_ent(g_iFinishEnt))
	{
		new Float:fOrigin[3]; get_entvar(g_iFinishEnt, var_origin, fOrigin);
		new iOrigin[3]; FVecIVec(fOrigin, iOrigin);
		
		formatex(g_szQuery, charsmax(g_szQuery), "UPDATE `maps` SET finishX = '%d', finishY = '%d', finishZ = '%d' WHERE mid=%d", 
			iOrigin[0], iOrigin[1], iOrigin[2], g_iMapIndex);
		
		SQL_ThreadQuery(g_hTuple, "Query_IngnoredHandle", g_szQuery);
	}
}
public Command_Rank(id)
{
	if(!g_ePlayerInfo[id][m_bAuthorized] || is_flooding(id)) return PLUGIN_HANDLED;
	
	new category = get_user_category(id);
	
	if(g_iBestTime[id][category] == 0)
	{
		client_print_color(id, print_team_default, "%s%s^1 You never reach finish.", PREFIX, g_szCategory[category]);
		return PLUGIN_CONTINUE;
	}
	
	ShowRank(id, category);
	
	return PLUGIN_CONTINUE;
}
public Command_Top15(id)
{
	if(!g_ePlayerInfo[id][m_bAuthorized] || is_flooding(id)) return PLUGIN_HANDLED;
	
	ShowTop15(id, get_user_category(id));
	
	return PLUGIN_CONTINUE;
}
public Command_Update(id)
{
	if(!g_ePlayerInfo[id][m_bAuthorized] || is_flooding(id)) return PLUGIN_HANDLED;
	
	new szName[32]; get_user_name(id, szName, charsmax(szName)); SQL_PrepareString(szName, szName, charsmax(szName));
	formatex(g_szQuery, charsmax(g_szQuery), "UPDATE `runners` SET nickname = '%s' WHERE id=%d", szName, g_ePlayerInfo[id][m_iPlayerIndex]);
	
	SQL_ThreadQuery(g_hTuple, "Query_IngnoredHandle", g_szQuery);
	
	return PLUGIN_CONTINUE;
}
CreateTimer()
{
	new ent = create_entity("info_target");	
	set_entvar(ent, var_classname, "timer_think");
	set_entvar(ent, var_nextthink, get_gametime() + 1.0);	
	register_think("timer_think", "Think_Timer");
}
public DB_Init()
{
	state mysql;
	
	new szDB[32]; get_pcvar_string(g_pCvars[SQL_DATABASE], szDB, charsmax(szDB));
	
	if(contain(szDB, ".") > 0)
	{
		state sqlite;
	}
		
	SQL_Init();
}
SQL_Init()<sqlite>
{
	SQL_SetAffinity("sqlite");
	
	new szDir[128]; get_localinfo("amxx_datadir", szDir, charsmax(szDir));
	new szDB[32]; get_pcvar_string(g_pCvars[SQL_DATABASE], szDB, charsmax(szDB));
	new szFile[128]; format(szFile, charsmax(szFile), "%s/%s", szDir, szDB);
	
	if(!file_exists(szFile))
	{
		new file = fopen(szFile, "w");
		if(!file)
		{
			new szMsg[128]; formatex(szMsg, charsmax(szMsg), "%s file not found and cant be created.", szFile);
			set_fail_state(szMsg);
		}
		fclose(file);
	}
	
	g_hTuple = SQL_MakeDbTuple("", "", "", szFile, 0);
	
	formatex(g_szQuery, charsmax(g_szQuery),
			"CREATE TABLE IF NOT EXISTS `runners`( \
			id 		INTEGER		PRIMARY KEY,\
			steamid		TEXT 	NOT NULL, \
			nickname	TEXT 	NOT NULL, \
			ip		TEXT 	NOT NULL, \
			nationality	TEXT 	NULL)");
	
	SQL_ThreadQuery(g_hTuple, "Query_IngnoredHandle", g_szQuery);
	
	formatex(g_szQuery, charsmax(g_szQuery),
			"CREATE TABLE IF NOT EXISTS `maps`( \
			mid 		INTEGER		PRIMARY KEY,\
			mapname		TEXT 		NOT NULL	UNIQUE, \
			finishX		INTEGER 	NOT NULL	DEFAULT 0, \
			finishY		INTEGER 	NOT NULL 	DEFAULT 0, \
			finishZ		INTEGER 	NOT NULL 	DEFAULT 0)");
	
	SQL_ThreadQuery(g_hTuple, "Query_IngnoredHandle", g_szQuery);
	
	formatex(g_szQuery, charsmax(g_szQuery),
			"CREATE TABLE IF NOT EXISTS `results`( \
			id			INTEGER 	NOT NULL, \
			mid 		INTEGER 	NOT NULL, \
			category	INTEGER 	NOT NULL, \
			besttime	INTEGER 	NOT NULL, \
			recorddate	DATETIME	NULL, \
			FOREIGN KEY(id) REFERENCES `runners`(id) ON DELETE CASCADE, \
			FOREIGN KEY(mid) REFERENCES `maps`(mid) ON DELETE CASCADE, \
			PRIMARY KEY(id, mid, category))");
	
	SQL_ThreadQuery(g_hTuple, "Query_IngnoredHandle", g_szQuery);
	
	set_task(1.0, "DelayedLoadMapInfo");
}
SQL_Init()<mysql>
{
	new szHost[32], szUser[32], szPass[32], szDB[32];
	get_pcvar_string(g_pCvars[SQL_HOST], szHost, charsmax(szHost));
	get_pcvar_string(g_pCvars[SQL_USER], szUser, charsmax(szUser));
	get_pcvar_string(g_pCvars[SQL_PASSWORD], szPass, charsmax(szPass));
	get_pcvar_string(g_pCvars[SQL_DATABASE], szDB, charsmax(szDB));
	
	g_hTuple = SQL_MakeDbTuple(szHost, szUser, szPass, szDB);
	
	if(g_hTuple == Empty_Handle)
	{
		set_fail_state("Cant create connection tuple");
	}
	
	formatex(g_szQuery, charsmax(g_szQuery),
			"CREATE TABLE IF NOT EXISTS `runners`(\
			id			INT(11)	UNSIGNED	AUTO_INCREMENT,\
			steamid		VARCHAR(32)	NOT NULL,\
			nickname	VARCHAR(32)	NOT NULL,\
			ip			VARCHAR(32)	NOT NULL,\
			nationality	VARCHAR(3)	NULL,\
			PRIMARY KEY(id))");
	
	SQL_ThreadQuery(g_hTuple, "Query_IngnoredHandle", g_szQuery);
	
	formatex(g_szQuery, charsmax(g_szQuery),
			"CREATE TABLE IF NOT EXISTS `maps`(\
			mid 		INT(11)	UNSIGNED 	AUTO_INCREMENT,\
			mapname		VARCHAR(64)	NOT NULL	UNIQUE,\
			finishX		INT(11) 	NOT NULL	DEFAULT 0,\
			finishY		INT(11) 	NOT NULL 	DEFAULT 0,\
			finishZ		INT(11) 	NOT NULL 	DEFAULT 0,\
			PRIMARY KEY(mid))");
	
	SQL_ThreadQuery(g_hTuple, "Query_IngnoredHandle", g_szQuery);
	
	formatex(g_szQuery, charsmax(g_szQuery),
			"CREATE TABLE IF NOT EXISTS `results`(\
			id			INT(11)		UNSIGNED,\
			mid			INT(11)		UNSIGNED,\
			category	INT(11)		NOT NULL,\
			besttime	INT(11)		NOT NULL,\
			recorddate	DATETIME	NULL,\
			FOREIGN KEY(id) REFERENCES `runners`(id) ON DELETE CASCADE,\
			FOREIGN KEY(mid) REFERENCES `maps`(mid) ON DELETE CASCADE,\
			PRIMARY KEY(id, mid, category))");
	
	SQL_ThreadQuery(g_hTuple, "Query_IngnoredHandle", g_szQuery);
	
	set_task(1.0, "DelayedLoadMapInfo");
}
public DelayedLoadMapInfo()
{
	get_mapname(g_szMapName, charsmax(g_szMapName));
	formatex(g_szQuery, charsmax(g_szQuery), "SELECT mid, finishX, finishY, finishZ FROM `maps` WHERE mapname='%s'", g_szMapName);
	SQL_ThreadQuery(g_hTuple, "Query_LoadMapHandle", g_szQuery);
}
public Query_LoadMapHandle(failstate, Handle:query, error[], errnum, data[], size)
{
	if(failstate != TQUERY_SUCCESS)
	{
		log_amx("SQL error[LoadMapHandle]: %s", error); return;
	}
	
	if(SQL_MoreResults(query))
	{
		g_iMapIndex = SQL_ReadResult(query, 0);
		
		CreateFinishI(SQL_ReadResult(query, 1),  SQL_ReadResult(query, 2),  SQL_ReadResult(query, 3));
	}
	else
	{		
		formatex(g_szQuery, charsmax(g_szQuery), "INSERT INTO `maps`(mapname) VALUES ('%s')", g_szMapName);
		SQL_ThreadQuery(g_hTuple, "Query_IngnoredHandle", g_szQuery);
		
		formatex(g_szQuery, charsmax(g_szQuery), "SELECT mid, finishX, finishY, finishZ FROM `maps` WHERE mapname='%s'", g_szMapName);
		SQL_ThreadQuery(g_hTuple, "Query_LoadMapHandle", g_szQuery);
	}

	if(g_iMapIndex)
	{
		for(new i = 1; i <= 32; i++)
		{
			if(g_ePlayerInfo[i][m_bConnected]) ClientAuthorization(i);
		}
		for(new i; i < Categories; i++)
		{
			ShowTop15(0, i);
		}
	}
}
public Query_IngnoredHandle(failstate, Handle:query, error[], errnum, data[], size)
{
	if(failstate != TQUERY_SUCCESS)
	{
		log_amx("SQL error[IngnoredHandle]: %s", error); return;
	}
}
public client_connect(id)
{
	g_ePlayerInfo[id][m_bAuthorized] = false;
	g_ePlayerInfo[id][m_bTimerStarted] = false;
	g_ePlayerInfo[id][m_bFinished] = false;
	g_ePlayerInfo[id][m_iPlayerIndex] = 0;
}
public client_putinserver(id)
{
	if(!is_user_bot(id) && !is_user_hltv(id))
	{
		g_ePlayerInfo[id][m_bConnected] = true;
		ClientAuthorization(id);
	}
}
ClientAuthorization(id)
{
	if(!g_iMapIndex) return;
	
	new szAuth[32]; get_user_authid(id, szAuth, charsmax(szAuth));
	
	new data[1]; data[0] = id;
	formatex(g_szQuery, charsmax(g_szQuery), "SELECT id, ip, nationality FROM `runners` WHERE steamid='%s'", szAuth);
	SQL_ThreadQuery(g_hTuple, "Query_LoadRunnerInfoHandler", g_szQuery, data, sizeof(data));
}
public Query_LoadRunnerInfoHandler(failstate, Handle:query, error[], errnum, data[], size)
{
	if(failstate != TQUERY_SUCCESS)
	{
		log_amx("SQL error[LoadRunnerInfo]: %s",error); return;
	}
	
	new id = data[0];
	if(!is_user_connected(id)) return;
	
	new szCode[5];
	
	if(SQL_MoreResults(query))
	{
		client_authorized_db(id, SQL_ReadResult(query, 0));
		
		SQL_ReadResult(query, 2, szCode, 1);
		
		if(szCode[0] == 0)
		{
			new szIP[32]; get_user_ip(id, szIP, charsmax(szIP), 1);
			
			get_nationality(id, szIP, szCode);
			formatex(g_szQuery, charsmax(g_szQuery), "UPDATE `runners` SET nationality='%s' WHERE id=%d", szCode, g_ePlayerInfo[id][m_iPlayerIndex]);
			SQL_ThreadQuery(g_hTuple, "Query_IngnoredHandle", g_szQuery);
		}
	}
	else
	{
		new szAuth[32]; get_user_authid(id, szAuth, charsmax(szAuth));
		new szIP[32]; get_user_ip(id, szIP, charsmax(szIP), 1);
		new szName[64]; get_user_name(id, szName, charsmax(szName));
		SQL_PrepareString(szName, szName, 63);
		
		get_nationality(id, szIP, szCode);
		
		formatex(g_szQuery, charsmax(g_szQuery), "INSERT INTO `runners` (steamid, nickname, ip, nationality) VALUES ('%s', '%s', '%s', '%s')", szAuth, szName, szIP, szCode);
		SQL_ThreadQuery(g_hTuple, "Query_InsertRunnerHandle", g_szQuery, data, size);
	}
}
public Query_InsertRunnerHandle(failstate, Handle:query, error[], errnum, data[], size)
{
	if(failstate != TQUERY_SUCCESS)
	{
		log_amx("SQL error[InsertRunner]: %s",error); return;
	}
	
	new id = data[0];
	if(!is_user_connected(id)) return;
	
	client_authorized_db(id , SQL_GetInsertId(query));
}
client_authorized_db(id, pid)
{
	g_ePlayerInfo[id][m_iPlayerIndex] = pid;
	g_ePlayerInfo[id][m_bAuthorized] = true;
	
	arrayset(g_iBestTime[id], 0, sizeof(g_iBestTime[]));

	LoadRunnerData(id);
}
LoadRunnerData(id)
{
	if(!g_ePlayerInfo[id][m_bAuthorized]) return;
	
	new data[1]; data[0] = id;
	
	formatex(g_szQuery, charsmax(g_szQuery), "SELECT * FROM `results` WHERE id=%d AND mid=%d", g_ePlayerInfo[id][m_iPlayerIndex], g_iMapIndex);
	SQL_ThreadQuery(g_hTuple, "Query_LoadDataHandle", g_szQuery, data, sizeof(data));
}
public Query_LoadDataHandle(failstate, Handle:query, error[], errnum, data[], size)
{
	if(failstate != TQUERY_SUCCESS)
	{
		log_amx("SQL Insert error: %s",error); return;
	}
	
	new id = data[0];
	if(!is_user_connected(id)) return;
	
	while(SQL_MoreResults(query))
	{
		new category = SQL_ReadResult(query, 2);
		g_iBestTime[id][category] = SQL_ReadResult(query, 3);
		
		SQL_NextRow(query);
	}
}
public client_disconnect(id)
{
	g_ePlayerInfo[id][m_bAuthorized] = false;
	g_ePlayerInfo[id][m_bConnected] = false;
}

public Think_DrawFinishBox(ent)
{
	for(new id = 1; id <= 32; id++)
	{
		if(g_ePlayerInfo[id][m_bConnected]) Create_Box(id, ent);
	}
	set_entvar(ent, var_nextthink, get_gametime() + BOXLIFE);
}
public Engine_TouchFinish(ent, id)
{
	if(g_ePlayerInfo[id][m_bTimerStarted] && !g_ePlayerInfo[id][m_bFinished])
	{
		Create_Box(id, ent);
		Forward_PlayerFinished(id);
	}
}
CreateFinishI(x, y, z)
{
	if(!x && !y && !z) return;
	
	new Float:fOrigin[3];
	fOrigin[0] = float(x);
	fOrigin[1] = float(y);
	fOrigin[2] = float(z);
	
	CreateFinish(fOrigin);
}
CreateFinish(const Float:fOrigin[3])
{	
	if(is_valid_ent(g_iFinishEnt)) remove_entity(g_iFinishEnt);
	
	g_iFinishEnt = 0;
	
	new ent = create_entity("trigger_multiple");
	set_entvar(ent, var_classname, FINISH_CLASSNAME);
	
	set_entvar(ent, var_origin, fOrigin);
	dllfunc(DLLFunc_Spawn, ent);
	
	entity_set_size(ent, Float:{-100.0, -100.0, -50.0}, Float:{100.0, 100.0, 50.0});
	
	set_entvar(ent, var_solid, SOLID_TRIGGER);
	set_entvar(ent, var_movetype, MOVETYPE_NONE);
	
	g_iFinishEnt = ent;
	
	set_entvar(ent, var_nextthink, get_gametime());
}
Create_Box(id, ent)
{
	new Float:maxs[3]; get_entvar(ent, var_absmax, maxs);
	new Float:mins[3]; get_entvar(ent, var_absmin, mins);
	
	new Float:fOrigin[3]; get_entvar(ent, var_origin, fOrigin);
	
	new Float:z, Float:fOff = -5.0;
	
	for(new i = 0; i < 3; i++)
	{
		z = fOrigin[2] + fOff;
		DrawLine(id, i, maxs[0], maxs[1], z, mins[0], maxs[1], z);
		DrawLine(id, i, maxs[0], maxs[1], z, maxs[0], mins[1], z);
		DrawLine(id, i, maxs[0], mins[1], z, mins[0], mins[1], z);
		DrawLine(id, i, mins[0], mins[1], z, mins[0], maxs[1], z);
		
		fOff += 5.0;
	}
}
DrawLine(id, i, Float:x1, Float:y1, Float:z1, Float:x2, Float:y2, Float:z2) 
{
	new Float:start[3], Float:stop[3];
	start[0] = x1;
	start[1] = y1;
	start[2] = z1;
	
	stop[0] = x2;
	stop[1] = y2;
	stop[2] = z2;
	Create_Line(id, i, start, stop);
}
Create_Line(id, num, const Float:start[], const Float:stop[])
{
	static const iColorFinished[][3] = {{0, 100, 0}, {0, 50, 0}, {0, 10, 0}};
	static const iColorRun[][3] = {{100, 0, 0}, {50, 0, 0}, {10, 0, 0}};
	
	new iColor[3];
	iColor = g_ePlayerInfo[id][m_bFinished] ? iColorFinished[num] : iColorRun[num];
	
	message_begin(MSG_ONE_UNRELIABLE, SVC_TEMPENTITY, _, id);
	write_byte(TE_BEAMPOINTS);
	engfunc(EngFunc_WriteCoord, start[0]);
	engfunc(EngFunc_WriteCoord, start[1]);
	engfunc(EngFunc_WriteCoord, start[2]);
	engfunc(EngFunc_WriteCoord, stop[0]);
	engfunc(EngFunc_WriteCoord, stop[1]);
	engfunc(EngFunc_WriteCoord, stop[2]);
	write_short(g_iSprite);
	write_byte(1);
	write_byte(5);
	write_byte(10*BOXLIFE);
	write_byte(50);
	write_byte(0);
	write_byte(iColor[0]);	// Red
	write_byte(iColor[1]);	// Green
	write_byte(iColor[2]);	// Blue
	write_byte(250);	// brightness
	write_byte(5);
	message_end();
}

public Think_Timer(ent)
{
	set_entvar(ent, var_nextthink, get_gametime() + 0.009);
	
	for(new id = 1; id <= 32; id++)
	{
		if(g_ePlayerInfo[id][m_bTimerStarted] && !g_ePlayerInfo[id][m_bFinished] && is_user_alive(id))
		{		
			display_time(id, get_running_time(id));
		}
	}
}

public SR_PlayerOnStart(id)
{
	HC_CBasePlayer_Spawn_Post(id);
}
public HC_CBasePlayer_Spawn_Post(id)
{
	g_ePlayerInfo[id][m_bTimerStarted] = false;
	hide_timer(id);
}
public HC_CheckStartTimer(id)
{
	if(g_ePlayerInfo[id][m_bAuthorized] && !g_ePlayerInfo[id][m_bTimerStarted])
	{
		StartTimer(id);
	}
}
StartTimer(id)
{
	if(!g_iFinishEnt) return;
	
	g_ePlayerInfo[id][m_bTimerStarted] = true;
	g_ePlayerInfo[id][m_bFinished] = false;
	g_ePlayerInfo[id][m_fStartRun] = _:get_gametime();
}

Forward_PlayerFinished(id)
{
	g_ePlayerInfo[id][m_bFinished] = true;
	
	new record = false;
	new iTime = get_running_time(id);
	new category = get_user_category(id);
	new szTime[32]; get_formated_time(iTime, szTime, charsmax(szTime));
	
	console_print(id, "%s Time: %s!", g_szCategory[category], szTime);
	
	if(g_iBestTime[id][category] == 0)
	{
		client_print_color(id, print_team_default, "%s%s^1 First finish.", PREFIX, g_szCategory[category]);
		SaveRunnerData(id, category, iTime);
	}
	else if(g_iBestTime[id][category] > iTime)
	{
		get_formated_time(g_iBestTime[id][category] - iTime, szTime, charsmax(szTime));
		console_print(id, "%s Own record: -%s!", g_szCategory[category], szTime);
		SaveRunnerData(id, category, iTime);
	}
	else if(g_iBestTime[id][category] < iTime)
	{
		get_formated_time(iTime - g_iBestTime[id][category], szTime, charsmax(szTime));
		console_print(id, "%s Own record: +%s!", g_szCategory[category], szTime);
	}
	else
	{
		client_print_color(id, print_team_default, "%s%s^1 Own record equal!", PREFIX, g_szCategory[category]);
	}
	
	if(g_iBestTimeofMap[category] == 0 || g_iBestTimeofMap[category] > iTime)
	{
		g_iBestTimeofMap[category] = iTime;
		
		new szName[32]; get_user_name(id, szName, charsmax(szName));
		get_formated_time(iTime, szTime, charsmax(szTime));
		
		client_print_color(0, print_team_default, "%s%s^3 %s^1 broke map record! Time:^3 %s", PREFIX, g_szCategory[category], szName, szTime);
		
		record = true;
	}
	if(g_iBestTimeofMap[category] != 0 && g_iBestTimeofMap[category]<iTime)
	{
		get_formated_time(iTime - g_iBestTimeofMap[category], szTime, charsmax(szTime));
		console_print(id, "%s Map record: -%s!", g_szCategory[category], szTime);
	}
	
	ExecuteForward(g_fwFinished, g_iReturn, id, iTime, record);
	
	hide_timer(id);
}
public SaveRunnerData(id, category, iTime)
{
	if(!g_ePlayerInfo[id][m_bAuthorized]) return;
	
	new query_type = g_iBestTime[id][category] ? 1 : 0;
	
	g_iBestTime[id][category] = iTime;
	new szRecordTime[32]; get_time("%Y-%m-%d %H:%M:%S", szRecordTime, charsmax(szRecordTime));
	
	if(query_type)
	{
		formatex(g_szQuery, charsmax(g_szQuery), "UPDATE `results` SET besttime=%d, recorddate='%s' WHERE id=%d AND mid=%d AND category=%d",
			iTime, szRecordTime, g_ePlayerInfo[id][m_iPlayerIndex], g_iMapIndex, category);
	}
	else
	{
		formatex(g_szQuery, charsmax(g_szQuery), "INSERT INTO `results` VALUES (%d, %d, %d, %d, '%s')",
			g_ePlayerInfo[id][m_iPlayerIndex], g_iMapIndex, category, iTime, szRecordTime);
	}
	
	SQL_ThreadQuery(g_hTuple, "Query_IngnoredHandle", g_szQuery);
}

ShowRank(id, category)
{
	formatex(g_szQuery, charsmax(g_szQuery), "SELECT COUNT(*) FROM `results` WHERE mid=%d AND category=%d AND besttime > 0 AND besttime < %d", 
			g_iMapIndex, category, g_iBestTime[id][category]);
		
	new data[2]; data[0] = id; data[1] = category;
	SQL_ThreadQuery(g_hTuple, "Query_LoadRankHandle", g_szQuery, data, sizeof(data));
}
public Query_LoadRankHandle(failstate, Handle:query, error[], errnum, data[], size)
{
	if(failstate != TQUERY_SUCCESS)
	{
		log_amx("SQL error[LoadRankHandle]: %s", error); return;
	}
	
	new id = data[0];
	new category = data[1];
	
	if(!is_user_connected(id) || !SQL_MoreResults(query)) return;
	
	new rank = SQL_ReadResult(query, 0) + 1;
	client_print_color(id, print_team_default, "%s%s^1 Your rank is %d!", PREFIX, g_szCategory[category], rank);
}

ShowTop15(id, category)
{
	formatex(g_szQuery, charsmax(g_szQuery), "SELECT nickname, besttime FROM `results` JOIN `runners` ON `runners`.id=`results`.id WHERE mid=%d AND category=%d AND besttime ORDER BY besttime ASC LIMIT 15", 
			g_iMapIndex, category);
		
	new data[2]; data[0] = id; data[1] = category;
	SQL_ThreadQuery(g_hTuple, "Query_LoadTop15Handle", g_szQuery, data, sizeof(data));
}
public Query_LoadTop15Handle(failstate, Handle:query, error[], errnum, data[], size)
{
	if(failstate != TQUERY_SUCCESS)
	{
		log_amx("SQL error[LoadTop15]: %s",error); return;
	}

	new id = data[0];
	if(!is_user_connected(id) && id != 0) return;
	
	new category = data[1];
	
	new iLen = 0, iMax = charsmax(g_szMotd);
	iLen = formatex(g_szMotd[iLen], iMax-iLen, "<meta charset=utf-8>");
	iLen += formatex(g_szMotd[iLen], iMax-iLen, "<style>{font:normal 10px} table, th, td{border: 1px solid black;border-collapse:collapse;text-align:center;}");
	iLen += formatex(g_szMotd[iLen], iMax-iLen, "</style><html><table width=100%%><thead><tr><th width=10%%>%s</th> <th width=50%%>%s</th><th width=20%%>%s</th><th width=20%%></th></tr></thead><tbody>", "Pos.", "Player", "Time");
	
	
	new i = 1;
	new iTime, szName[32], szTime[32];
	while(SQL_MoreResults(query))
	{
		SQL_ReadResult(query, 0, szName, 31);
		iTime = SQL_ReadResult(query, 1);
		get_formated_time(iTime, szTime, 31);
		
		iLen += formatex(g_szMotd[iLen], iMax-iLen, "<tr><td>%d</td><td>%s</td>", i, szName);
		if(i == 1)
		{
			g_iBestTimeofMap[category] = iTime;
			iLen += formatex(g_szMotd[iLen], iMax-iLen, "<td>%s</td><td></td>",  szTime);
			if(id == 0) return;
		}
		else
		{
			iLen += formatex(g_szMotd[iLen], iMax-iLen, "<td>%s</td>", szTime);
			
			get_formated_time(iTime-g_iBestTimeofMap[category] , szTime, 31);
			iLen += formatex(g_szMotd[iLen], iMax-iLen, "<td>+%s</td>", szTime);
		}
		iLen += formatex(g_szMotd[iLen], iMax-iLen, "</tr>");
		
		i++;
		SQL_NextRow(query);
	}
	iLen += formatex(g_szMotd[iLen], iMax-iLen, "</pre>");
	show_motd(id, g_szMotd, "Top15");
}


hide_timer(id)
{
	show_status(id, "");
}
display_time(id, iTime)
{
	show_status(id, "Time: %d:%02d.%03ds", iTime / 60000, (iTime / 1000) % 60, iTime % 1000);
}
show_status(id, const szMsg[], any:...)
{
	static szStatus[128]; vformat(szStatus, charsmax(szStatus), szMsg, 3);
	static StatusText; if(!StatusText) StatusText = get_user_msgid("StatusText");
	
	message_begin(MSG_ONE_UNRELIABLE, StatusText, _, id);
	write_byte(0);
	write_string(szStatus);
	message_end();
}
get_running_time(id)
{
	return floatround((get_gametime() - g_ePlayerInfo[id][m_fStartRun]) * 1000, floatround_ceil);
}
get_formated_time(iTime, szTime[], size)
{
	formatex(szTime, size, "%d:%02d.%03ds", iTime / 60000, (iTime / 1000) % 60, iTime % 1000);
}
get_nationality(id, const szIP[], szCode[5])
{
	new szTemp[3];
	if(geoip_code2_ex(szIP, szTemp))
	{
		copy(szCode, 4, szTemp);
	}
	else
	{
		get_user_info(id, "lang", szCode, 2);
		SQL_PrepareString(szCode, szCode, 4);
	}
}
bool:is_flooding(id)
{
	static Float:fAntiFlood[33];
	new bool:fl = false;
	new Float:fNow = get_gametime();
	
	if((fNow-fAntiFlood[id]) < 1.0) fl = true;
	
	fAntiFlood[id] = fNow;
	return fl;
}
stock SQL_PrepareString(const szQuery[], szOutPut[], size)
{
	copy(szOutPut, size, szQuery);
	replace_all(szOutPut, size, "'", "\'");
	replace_all(szOutPut,size, "`", "\`");
	replace_all(szOutPut,size, "\\", "\\\\");
}
