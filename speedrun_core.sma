#include <amxmodx>
#include <fakemeta>
#include <hamsandwich>
#include <reapi>

#if AMXX_VERSION_NUM < 183
#include <colorchat>
#endif
	
#define PLUGIN "Speedrun: Core"
#define VERSION "0.2"
#define AUTHOR "Mistrick"

#pragma semicolon 1

#define MAX_PLAYERS 32

#define FPS_LIMIT 500
#define CRAZYSPEED_BOOST 250.0
#define FASTRUN_AIRACCELERATE -55.0

new const PREFIX[] = "^4[Speedrun]";

enum (+=100)
{
	TASK_SHOWSPEED = 100,
	TASK_CHECKFRAMES
};
enum
{
	Cat_FastRun = 1,
	Cat_CrazySpeed = 2,
	Cat_100fps = 100,
	Cat_200fps = 200,
	Cat_250fps = 250,
	Cat_333fps = 333,
	Cat_500fps = 500
};
enum _:PlayerData
{
	m_Bhop,
	m_Speed,
	m_Frames,
	m_Category,
	m_SavePoint
};

new g_bStartPosition, Float:g_fStartOrigin[3], Float:g_fStartVAngles[3];
new g_ePlayerInfo[33][PlayerData];
new g_szMapName[32];
new g_iSyncHudSpeed;

public plugin_init()
{
	register_plugin(PLUGIN, VERSION, AUTHOR);
	
	register_clcmd("say /setstart", "Command_SetStart", ADMIN_RCON);
	register_clcmd("say /start", "Command_Start");
	register_clcmd("say /bhop", "Command_Bhop");
	register_clcmd("say /speed", "Command_Speed");
	register_clcmd("say /spec", "Command_Spec");
	register_clcmd("say /game", "CategoryMenu");
	register_clcmd("say /fps", "SpeedrunMenu");
	register_clcmd("drop", "CategoryMenu");
	
	register_menucmd(register_menuid("CategoryMenu"), 1023, "CategoryMenu_Handler");
	register_menucmd(register_menuid("SpeedrunMenu"), 1023, "SpeedrunMenu_Handler");
	
	register_message(get_user_msgid("ScoreInfo"), "Message_ScoreInfo");
	
	RegisterHookChain(RG_PM_AirMove, "HC_PM_AirMove_Pre", false);
	RegisterHookChain(RG_CBasePlayer_Jump, "HC_CBasePlayer_Jump_Pre", false);
	RegisterHookChain(RG_CBasePlayer_Spawn, "HC_CBasePlayer_Spawn_Post", true);
	RegisterHookChain(RG_CBasePlayer_Killed, "HC_CBasePlayer_Killed_Pre", false);
	RegisterHookChain(RG_CBasePlayer_Killed, "HC_CBasePlayer_Killed_Post", true);
	RegisterHookChain(RG_CBasePlayer_PreThink, "HC_CBasePlayer_PreThink", false);
	RegisterHookChain(RG_CBasePlayer_GiveDefaultItems, "HC_CBasePlayer_GiveDefaultItems", false);
	RegisterHookChain(RG_CSGameRules_DeadPlayerWeapons, "HC_CSGR_DeadPlayerWeapons_Pre", false);
	
	register_forward(FM_ClientKill, "FM_ClientKill_Pre", false);
	
	set_msg_block(get_user_msgid("AmmoPickup"), BLOCK_SET);
	set_msg_block(get_user_msgid("ClCorpse"), BLOCK_SET);
	set_msg_block(get_user_msgid("DeathMsg"), BLOCK_SET);
	set_msg_block(get_user_msgid("WeapPickup"), BLOCK_SET);
	
	g_iSyncHudSpeed = CreateHudSyncObj();
	
	set_task(0.1, "Task_ShowSpeed", TASK_SHOWSPEED, .flags = "b");
	set_task(1.0, "Task_CheckFrames", TASK_CHECKFRAMES, .flags = "b");
	
	set_cvar_num("mp_autoteambalance", 0);
	set_cvar_num("mp_round_infinite", 1);
	set_cvar_num("mp_freezetime", 0);
	set_cvar_num("mp_limitteams", 0);
	set_cvar_num("mp_auto_join_team", 1);
	set_cvar_string("humans_join_team", "CT");
}

new Trie:g_tRemoveEntities, g_iForwardSpawn;

public plugin_precache()
{	
	new const szRemoveEntities[][] = 
	{
		"func_bomb_target", "func_escapezone", "func_hostage_rescue", "func_vip_safetyzone", "info_vip_start",
		"hostage_entity", "info_bomb_target", "func_buyzone","info_hostage_rescue", "monster_scientist",
		"player_weaponstrip", "game_player_equip"
	};
	g_tRemoveEntities = TrieCreate();
	for(new i = 0; i < sizeof(szRemoveEntities); i++)
	{
		TrieSetCell(g_tRemoveEntities, szRemoveEntities[i], i);
	}
	g_iForwardSpawn = register_forward(FM_Spawn, "FakeMeta_Spawn_Pre", false);
	engfunc(EngFunc_CreateNamedEntity, engfunc(EngFunc_AllocString, "func_buyzone"));
}
public FakeMeta_Spawn_Pre(ent)
{
	if(!pev_valid(ent)) return FMRES_IGNORED;
	
	new szClassName[32]; get_entvar(ent, var_classname, szClassName, charsmax(szClassName));
	if(TrieKeyExists(g_tRemoveEntities, szClassName))
	{
		engfunc(EngFunc_RemoveEntity, ent);
		return FMRES_SUPERCEDE;
	}
	return FMRES_IGNORED;
}
public plugin_cfg()
{
	TrieDestroy(g_tRemoveEntities);
	unregister_forward(FM_Spawn, g_iForwardSpawn, 0);
	
	get_mapname(g_szMapName, charsmax(g_szMapName));
	LoadStartPosition();
	SetGameName();
	BlockChangingTeam();
}
LoadStartPosition()
{
	new szDir[128]; get_localinfo("amxx_datadir", szDir, charsmax(szDir));
	format(szDir, charsmax(szDir), "%s/speedrun/", szDir);
	
	if(!dir_exists(szDir))	mkdir(szDir);
	
	new szFile[128]; formatex(szFile, charsmax(szFile), "%s%s.bin", szDir, g_szMapName);
	
	if(!file_exists(szFile)) return;
	
	new file = fopen(szFile, "rb");
	fread_blocks(file, _:g_fStartOrigin, sizeof(g_fStartOrigin), BLOCK_INT);
	fread_blocks(file, _:g_fStartVAngles, sizeof(g_fStartVAngles), BLOCK_INT);
	fclose(file);
	
	g_bStartPosition = true;
}
SetGameName()
{
	new szGameName[32]; formatex(szGameName, charsmax(szGameName), "Speedrun v%s", VERSION);
	set_member_game(m_GameDesc, szGameName);
}
BlockChangingTeam()
{
	new szCmds[][] = {"jointeam", "joinclass"};
	for(new i; i < sizeof(szCmds); i++)
	{
		register_clcmd(szCmds[i], "Command_BlockJointeam");
	}
	register_clcmd("chooseteam", "Command_Chooseteam");
}
public plugin_natives()
{
	register_native("get_user_category", "_get_user_category", 1);
	register_native("set_user_category", "_set_user_category", 1);
}
public _get_user_category(id)
{
	return g_ePlayerInfo[id][m_Category];
}
public _set_user_category(id, category)
{
	g_ePlayerInfo[id][m_Category] = category;
	if(is_user_alive(id)) ExecuteHamB(Ham_CS_RoundRespawn, id);
}
public client_putinserver(id)
{
	g_ePlayerInfo[id][m_Bhop] = true;
	g_ePlayerInfo[id][m_Speed] = true;
	g_ePlayerInfo[id][m_Category] = Cat_500fps;
}
public client_disconnect(id)
{
	g_ePlayerInfo[id][m_Speed] = false;
}
public Command_SetStart(id, flag)
{
	if((~get_user_flags(id) & flag) || !is_user_alive(id)) return PLUGIN_HANDLED;
	
	get_entvar(id, var_origin, g_fStartOrigin);
	get_entvar(id, var_v_angle, g_fStartVAngles);
	
	g_bStartPosition = true;
	
	SaveStartPosition(g_szMapName, g_fStartOrigin, g_fStartVAngles);
	
	client_print_color(id, print_team_blue, "%s^3 Start position has been set.", PREFIX);
	
	return PLUGIN_HANDLED;
}
SaveStartPosition(map[], Float:origin[3], Float:vangles[3])
{
	new szDir[128]; get_localinfo("amxx_datadir", szDir, charsmax(szDir));
	new szFile[128]; formatex(szFile, charsmax(szFile), "%s/speedrun/%s.bin", szDir, map);
	
	new file = fopen(szFile, "wb");
	fwrite_blocks(file, _:origin, sizeof(origin), BLOCK_INT);
	fwrite_blocks(file, _:vangles, sizeof(vangles), BLOCK_INT);
	fclose(file);
}
public Command_Start(id)
{
	if(!is_user_alive(id)) return PLUGIN_HANDLED;
	
	if(g_ePlayerInfo[id][m_SavePoint])
	{
		//SetPosition(id, g_fSavedOrigin[id], g_fSavedVAngles[id]);
	}
	else if(g_bStartPosition)
	{
		SetPosition(id, g_fStartOrigin, g_fStartVAngles);
	}
	else
	{
		ExecuteHamB(Ham_CS_RoundRespawn, id);
	}
	
	//ExecuteForward(g_fwOnStart, g_iReturn, id);
	
	return PLUGIN_HANDLED;
}
SetPosition(id, Float:origin[3], Float:vangles[3])
{
	set_entvar(id, var_velocity, Float:{0.0, 0.0, 0.0});
	set_entvar(id, var_v_angle, vangles);
	set_entvar(id, var_angles, vangles);
	set_entvar(id, var_fixangle, 1);
	set_entvar(id, var_health, 100.0);
	engfunc(EngFunc_SetOrigin, id, origin);
}
public Command_Bhop(id)
{
	g_ePlayerInfo[id][m_Bhop] = !g_ePlayerInfo[id][m_Bhop];
	client_print_color(id, print_team_default, "%s^1 Bhop is^3 %s^1.", PREFIX, g_ePlayerInfo[id][m_Bhop] ? "enabled" : "disabled");
}
public Command_Speed(id)
{
	g_ePlayerInfo[id][m_Speed] = !g_ePlayerInfo[id][m_Speed];
	client_print_color(id, print_team_default, "^4%s^1 Speedometer is^3 %s^1.", PREFIX, g_ePlayerInfo[id][m_Speed] ? "enabled" : "disabled");
}
public Command_Spec(id)
{
	if(get_member(id, m_iTeam) != TEAM_SPECTATOR)
	{
		rg_join_team(id, TEAM_SPECTATOR);
	}
	else
	{
		rg_set_user_team(id, TEAM_CT);
		ExecuteHamB(Ham_CS_RoundRespawn, id);
		HC_CBasePlayer_GiveDefaultItems(id);
	}
}
public Command_BlockJointeam(id)
{
	return PLUGIN_HANDLED;
}
public Command_Chooseteam(id)
{
	client_print_color(id, print_team_default, "%s^1 Sometime there will be menu.", PREFIX);
	return PLUGIN_HANDLED;
}
public CategoryMenu(id)
{
	new szMenu[128], len = 0;
	
	len = formatex(szMenu[len], charsmax(szMenu) - len, "\yCategory Menu^n^n");
	len += formatex(szMenu[len], charsmax(szMenu) - len, "\r1. %sSpeedrun^n", g_ePlayerInfo[id][m_Category] > Cat_CrazySpeed ? "\r" : "\w");
	len += formatex(szMenu[len], charsmax(szMenu) - len, "\r2. %sFastrun^n", g_ePlayerInfo[id][m_Category] == Cat_FastRun ? "\r" : "\w");
	len += formatex(szMenu[len], charsmax(szMenu) - len, "\r3. %sCrazySpeed^n", g_ePlayerInfo[id][m_Category] == Cat_CrazySpeed ? "\r" : "\w");
	len += formatex(szMenu[len], charsmax(szMenu) - len, "^n^n^n^n^n^n\r0. \wExit");
	
	show_menu(id, (1 << 0)|(1 << 1)|(1 << 2)|(1 << 9), szMenu, -1, "CategoryMenu");
	return PLUGIN_HANDLED;
}
public CategoryMenu_Handler(id, key)
{
	switch(key)
	{
		case 0: SpeedrunMenu(id);
		case 1: g_ePlayerInfo[id][m_Category] = Cat_FastRun;
		case 2: g_ePlayerInfo[id][m_Category] = Cat_CrazySpeed;
	}
	
	if(key && key <= 2)
	{
		if(is_user_alive(id)) ExecuteHamB(Ham_CS_RoundRespawn, id);
		
		//ExecuteForward(g_fwChangeCategory, g_iReturn, id, g_ePlayerInfo[id][m_Category]);
	}
}
public SpeedrunMenu(id)
{
	new szMenu[128], len = 0;
	
	len = formatex(szMenu[len], charsmax(szMenu) - len, "\ySpeedrun Menu^n^n");
	len += formatex(szMenu[len], charsmax(szMenu) - len, "\r1. %s100 FPS^n", g_ePlayerInfo[id][m_Category] == Cat_100fps ? "\r" : "\w");
	len += formatex(szMenu[len], charsmax(szMenu) - len, "\r2. %s200 FPS^n", g_ePlayerInfo[id][m_Category] == Cat_200fps ? "\r" : "\w");
	len += formatex(szMenu[len], charsmax(szMenu) - len, "\r3. %s250 FPS^n", g_ePlayerInfo[id][m_Category] == Cat_250fps ? "\r" : "\w");
	len += formatex(szMenu[len], charsmax(szMenu) - len, "\r4. %s333 FPS^n", g_ePlayerInfo[id][m_Category] == Cat_333fps ? "\r" : "\w");
	len += formatex(szMenu[len], charsmax(szMenu) - len, "\r5. %s500 FPS^n", g_ePlayerInfo[id][m_Category] == Cat_500fps ? "\r" : "\w");
	len += formatex(szMenu[len], charsmax(szMenu) - len, "^n^n^n^n\r0. \wExit");
	
	show_menu(id, (1 << 0)|(1 << 1)|(1 << 2)|(1 << 3)|(1 << 4)|(1 << 9), szMenu, -1, "SpeedrunMenu");
	return PLUGIN_HANDLED;
}
public SpeedrunMenu_Handler(id, key)
{
	switch(key)
	{
		case 0: g_ePlayerInfo[id][m_Category] = Cat_100fps;
		case 1: g_ePlayerInfo[id][m_Category] = Cat_200fps;
		case 2: g_ePlayerInfo[id][m_Category] = Cat_250fps;
		case 3: g_ePlayerInfo[id][m_Category] = Cat_333fps;
		case 4: g_ePlayerInfo[id][m_Category] = Cat_500fps;
	}
	if(key != 9)
	{
		if(is_user_alive(id)) ExecuteHamB(Ham_CS_RoundRespawn, id);
		
		//ExecuteForward(g_fwChangeCategory, g_iReturn, id, g_ePlayerInfo[id][m_Category]);
	}
}
//*******************************************************************//
public Message_ScoreInfo(Msgid, Dest, id)
{
	new player = get_msg_arg_int(1);
	set_msg_arg_int(2, ARG_SHORT, 0);//frags
	set_msg_arg_int(3, ARG_SHORT, g_ePlayerInfo[player][m_Category]);//deaths
}
//*******************************************************************//
public HC_CBasePlayer_Spawn_Post(id)
{
	if(!is_user_alive(id)) return HC_CONTINUE;
	
	if(g_bStartPosition)
	{
		Command_Start(id);
	}
	
	return HC_CONTINUE;
}
public HC_CBasePlayer_Killed_Pre()
{
	SetHookChainArg(3, ATYPE_INTEGER, 1);
}
public HC_CBasePlayer_Killed_Post(id)
{
	if(TEAM_UNASSIGNED < get_member(id, m_iTeam) < TEAM_SPECTATOR)
	{
		ExecuteHamB(Ham_CS_RoundRespawn, id);
	}
}
public HC_CBasePlayer_GiveDefaultItems(id)
{
	rg_remove_all_items(id, false);
	rg_give_item(id, "weapon_knife");
	return HC_SUPERCEDE;
}
public HC_CBasePlayer_Jump_Pre(id)
{
	if(!g_ePlayerInfo[id][m_Bhop]) return HC_CONTINUE;
	
	new flags = get_entvar(id, var_flags);
	
	if((flags & FL_WATERJUMP) || !(flags & FL_ONGROUND)  || get_entvar(id, var_waterlevel) >= 2) return HC_CONTINUE;
	
	new Float:fVelocity[3], Float:fAngles[3];
	
	get_entvar(id, var_velocity, fVelocity);
	
	if(g_ePlayerInfo[id][m_Category] == Cat_CrazySpeed)
	{		
		get_entvar(id, var_angles, fAngles);
		
		fVelocity[0] += floatcos(fAngles[1], degrees) * CRAZYSPEED_BOOST;
		fVelocity[1] += floatsin(fAngles[1], degrees) * CRAZYSPEED_BOOST;
	}
	
	fVelocity[2] = 250.0;
	
	set_entvar(id, var_velocity, fVelocity);
	set_entvar(id, var_gaitsequence, 6);
	
	return HC_CONTINUE;
}
public HC_PM_AirMove_Pre(id)
{
	if(g_ePlayerInfo[id][m_Category] != Cat_FastRun) return HC_CONTINUE;
	
	static bFastRun[33];
	new buttons = get_entvar(id, var_button);
	
	if((buttons & IN_BACK) && (buttons & IN_JUMP) && !bFastRun[id])
	{
		bFastRun[id] = true;
	}
	if((get_member(id, m_afButtonReleased) & IN_BACK) && bFastRun[id])
	{
		bFastRun[id] = false;
	}
	if(bFastRun[id])
	{
		set_movevar(mv_airaccelerate, FASTRUN_AIRACCELERATE);
	}
	
	return HC_CONTINUE;
}
public HC_CSGR_DeadPlayerWeapons_Pre(id)
{
    SetHookChainReturn(ATYPE_INTEGER, GR_PLR_DROP_GUN_NO);
    return HC_SUPERCEDE;
}
public HC_CBasePlayer_PreThink(id)
{
	g_ePlayerInfo[id][m_Frames]++;
}
//*******************************************************************//
public FM_ClientKill_Pre(id)
{
	Command_Start(id);
	return FMRES_SUPERCEDE;
}
//*******************************************************************//
public Task_ShowSpeed()
{
	new Float:fSpeed, Float:fVelocity[3], iSpecMode;
	for(new id = 1, target; id <= MAX_PLAYERS; id++)
	{
		if(!g_ePlayerInfo[id][m_Speed]) continue;
		
		iSpecMode = get_entvar(id, var_iuser1);
		target = (iSpecMode == 1  || iSpecMode == 2 || iSpecMode == 4) ? get_entvar(id, var_iuser2) : id;
		get_entvar(target, var_velocity, fVelocity);
		
		fSpeed = vector_length(fVelocity);
		
		set_hudmessage(0, 55, 255, -1.0, 0.7, 0, _, 0.1, _, _, 2);
		ShowSyncHudMsg(id, g_iSyncHudSpeed, "%3.2f", fSpeed);
	}
}
public Task_CheckFrames()
{
	for(new id = 1; id <= MAX_PLAYERS; id++)
	{
		if(!is_user_alive(id))
		{
			g_ePlayerInfo[id][m_Frames] = 0;
			continue;
		}
		
		if(g_ePlayerInfo[id][m_Category] > Cat_CrazySpeed && g_ePlayerInfo[id][m_Frames] > g_ePlayerInfo[id][m_Category] + 10
			|| g_ePlayerInfo[id][m_Category] <= Cat_CrazySpeed && g_ePlayerInfo[id][m_Frames] > FPS_LIMIT + 10)
		{
			ExecuteHamB(Ham_CS_RoundRespawn, id);
			client_print_color(id, print_team_red, "%s^3 Write in your console fps_max %d!", PREFIX, g_ePlayerInfo[id][m_Category] > Cat_CrazySpeed ? g_ePlayerInfo[id][m_Category] : FPS_LIMIT);
		}
		g_ePlayerInfo[id][m_Frames] = 0;
	}
}
