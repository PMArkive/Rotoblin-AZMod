/*
//-------------------------------------------------------------------------------------------------------------------
// Version 1: Prevents Survivors from picking up Players in the following situations:
//-------------------------------------------------------------------------------------------------------------------
// - Incapped Player is taking Spit Damage.
// - Players doing the pick-up gets hit by the Tank (Punch or Rock)
//
//-------------------------------------------------------------------------------------------------------------------
// Version 1.1: Prevents Survivors from switching from their current item to another without client requesting so:
//-------------------------------------------------------------------------------------------------------------------
// - Player no longer switches to pills when a teammate passes them pills through "M2".
// - Player picks up a Secondary Weapon while not on their Secondary Weapon. (Dual Pistol will force a switch though)
// - Added CVars for Pick-ups/Switching Item
//
//-------------------------------------------------------------------------------------------------------------------
// Version 1.2: Added Client-side Flags so that players can choose whether or not to make use of the Server's flags.
//-------------------------------------------------------------------------------------------------------------------
// - Welp, there's only one change.. so yeah. Enjoy!
//
//-------------------------------------------------------------------------------------------------------------------
// Version 2.0: Added way to detect Dual Pistol pick-up and block so.
//-------------------------------------------------------------------------------------------------------------------
// - Via hacky memory patch. 
//
//-------------------------------------------------------------------------------------------------------------------
// Version 3.0: General rework and dualies patch review
//-------------------------------------------------------------------------------------------------------------------
// - Should be perfect now? (hurray)
//
//-------------------------------------------------------------------------------------------------------------------
// Version 4.0: No switch to primary as well
//-------------------------------------------------------------------------------------------------------------------
// - Behave like a modern.
//
//-------------------------------------------------------------------------------------------------------------------
// DONE:
//-------------------------------------------------------------------------------------------------------------------
// - Be a nice guy and less lazy, allow the plugin to work flawlessly with other's peoples needs.. It doesn't require much attention.
// - Find cleaner methods to detect and handle functions.
*/

#define PLUGIN_VERSION "4.1"

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>
#define L4D2UTIL_STOCKS_ONLY
#include <l4d_weapon_stocks>
#include <multicolors>
#include <dhooks>
#include <sourcescramble>
#include <clientprefs>

#define FLAGS_SWITCH_WEAPONS              1
#define FLAGS_SWITCH_PILLS                2

#define TEAM_SURVIVOR                     2
#define TEAM_INFECTED                     3

#define AddonBits_L4D1_Slot1               (1 << 4) // 16
#define AddonBits_L4D1_Slot2               (1 << 5) // 32
#define AddonBits_L4D1_Slot3               (1 << 2) // 4
#define AddonBits_L4D1_Slot4               (1 << 0) // 1
#define AddonBits_L4D1_Slot5               (1 << 1) // 2
#define AddonBits_L4D1_SmokerTongue        (1 << 3) // 8

bool
	bLateLoad,
	bCantSwitchHealth[MAXPLAYERS+1],
	bCantSwitchSecondary[MAXPLAYERS+1],
	bPreventValveSwitch[MAXPLAYERS+1];
	
int
	iSwitchFlags[MAXPLAYERS+1],
	SwitchFlags;

MemoryPatch
	g_hPatch;

Cookie 
	g_hSwitchCookie;

public Plugin myinfo = 
{
	name = "L4D2 Pick-up Changes",
	author = "Sir, Forgetest, l4d1 port by Harry", //Update syntax A1m`
	description = "Alters a few things regarding picking up/giving items and incapped Players.",
	version = PLUGIN_VERSION,
	url = "https://github.com/Target5150/MoYu_Server_Stupid_Plugins"
}

#define GAMEDATA_FILE "l4d_pickup"
#define COOKIE_NAME "l4d_pickup_switch_cookie"
#define KEY_FUNCTION "CTerrorGun::EquipSecondWeapon"
#define KEY_PATCH_SURFIX "__SkipWeaponDeploy"
#define KEY_FUNCTION_2 "CTerrorGun::RemoveSecondWeapon"

void LoadSDK()
{
	GameData conf = new GameData(GAMEDATA_FILE);
	if (conf == null)
		SetFailState("Missing gamedata \"" ... GAMEDATA_FILE ..."\"");
	
	DynamicDetour hDetour = DynamicDetour.FromConf(conf, KEY_FUNCTION);
	if (!hDetour)
		SetFailState("Missing detour setup \""...KEY_FUNCTION..."\"");
	if (!hDetour.Enable(Hook_Pre, DTR_OnEquipSecondWeapon))
		SetFailState("Failed to pre-detour \""...KEY_FUNCTION..."\"");
	if (!hDetour.Enable(Hook_Post, DTR_OnEquipSecondWeapon_Post))
		SetFailState("Failed to post-detour \""...KEY_FUNCTION..."\"");
	
	delete hDetour;
	
	hDetour = DynamicDetour.FromConf(conf, KEY_FUNCTION_2);
	if (!hDetour)
		SetFailState("Missing detour setup \""...KEY_FUNCTION_2..."\"");

	else
	{
		if (!hDetour.Enable(Hook_Pre, DTR_OnRemoveSecondWeapon_Ev))
			SetFailState("Failed to pre-detour \""...KEY_FUNCTION_2..."\"");
	}
	
	delete hDetour;
	
	g_hPatch = MemoryPatch.CreateFromConf(conf, KEY_FUNCTION...KEY_PATCH_SURFIX);
	if (!g_hPatch.Validate())
		SetFailState("Failed to validate memory patch \""...KEY_FUNCTION...KEY_PATCH_SURFIX..."\"");
	
	delete conf;
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	switch (GetEngineVersion())
	{
		case Engine_Left4Dead: {}
		default:
		{
			strcopy(error, err_max, "Plugin supports only Left 4 Dead 1");
			return APLRes_SilentFailure;
		}
	}

	bLateLoad = late;
	return APLRes_Success;
}

public void OnPluginStart()
{
	LoadSDK();
	
	ConVar cv = CreateConVar("pickup_switch_flags", "3", "Flags for Switching from current item (1:Weapons, 2: Passed Pills)", _, true, 0.0, true, 3.0);
	SwitchCVarChanged(cv, "", "");
	cv.AddChangeHook(SwitchCVarChanged);
	
	InitSwitchCookie();
	
	//RegConsoleCmd("sm_secondary", ChangeSecondaryFlags);
	
	if (bLateLoad)
		for (int i = 1; i <= MaxClients; i++)
			if (IsClientInGame(i))
				OnClientPutInServer(i);
}

public void OnPluginEnd()
{
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i))
			OnClientDisconnect(i);
}

void InitSwitchCookie()
{
	if ((g_hSwitchCookie = Cookie.Find(COOKIE_NAME)) == null)
	{
		g_hSwitchCookie = new Cookie(COOKIE_NAME,
								"Flags for Switching from current item for every client.",
								CookieAccess_Public);
	}
}


/* ---------------------------------
//                                 |
//       Standard Client Stuff     |
//                                 |
// -------------------------------*/
public void OnClientPutInServer(int client)
{
	HookValidClient(client, true);
	iSwitchFlags[client] = SwitchFlags;
}

public void OnClientDisconnect(int client)
{
	HookValidClient(client, false);
	
	if (!IsFakeClient(client))
		SetSwitchCookie(client, iSwitchFlags[client]);
}
/*
Action ChangeSecondaryFlags(int client, int args)
{
	if (client && IsClientInGame(client)) {
		if (iSwitchFlags[client] == 0) {
			iSwitchFlags[client] = SwitchFlags;
			CPrintToChat(client, "{blue}[{default}ItemSwitch{blue}] {default}Auto Switch to Weapons/Pills on pick-up/given: {blue}OFF");
		} else {
			iSwitchFlags[client] = 0;
			CPrintToChat(client, "{blue}[{default}ItemSwitch{blue}] {default}Auto Switch to Weapons/Pills on pick-up/given: {blue}ON");
		}
	}
	return Plugin_Handled;
}
*/

/* ---------------------------------
//                                 |
//       Yucky Timer Method~       |
//                                 |
// -------------------------------*/
void DelaySwitchHealth(any client)
{
	bCantSwitchHealth[client] = false;
}

void DelaySwitchSecondary(any client)
{
	bCantSwitchSecondary[client] = false;
}

void DelayValveSwitch(any client)
{
	bPreventValveSwitch[client] = false;
}


/* ---------------------------------
//                                 |
//         SDK Hooks, Fun!         |
//                                 |
// -------------------------------*/

Action WeaponCanSwitchTo(int client, int weapon)
{
	L4D2WeaponId wep = L4D2_GetWeaponId(weapon);
	
	if (wep == L4D2WeaponId_None) {
		return Plugin_Continue;
	}
	
	L4D2WeaponSlot wepslot = GetSlotFromWeaponId(wep);
	if (wepslot == L4D2WeaponSlot_None) {
		return Plugin_Continue;
	}

	//PrintToChatAll("%N - iSwitchFlags[client]: %d, wepslot: %d, health: %d, weapon: %d", client, iSwitchFlags[client], wepslot, bCantSwitchHealth[client], bCantSwitchSecondary[client]);

	// Health Items.
	if ((iSwitchFlags[client] & FLAGS_SWITCH_PILLS)&& wepslot == L4D2WeaponSlot_LightHealthItem && bCantSwitchHealth[client]) {
		return Plugin_Stop;
	}
	
	//Weapons.
	if ((iSwitchFlags[client] & FLAGS_SWITCH_WEAPONS) && (wepslot == L4D2WeaponSlot_Primary || wepslot == L4D2WeaponSlot_Secondary) && bCantSwitchSecondary[client]) {
		return Plugin_Stop;
	}
	
	return Plugin_Continue;
}

Action WeaponEquip(int client, int weapon)
{
	// New Weapon
	L4D2WeaponId wep = L4D2_GetWeaponId(weapon);

	if (wep == L4D2WeaponId_None) {
		return Plugin_Continue;
	}
	
	// Weapon Currently Using
	int active_weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	L4D2WeaponId wepname = L4D2_GetWeaponId(active_weapon);
	
	if (wepname == L4D2WeaponId_None) {
		return Plugin_Continue;
	}
	
	// Also Check if Survivor is incapped to make sure no issues occur (Melee players get given a pistol for example)
	if (!IsPlayerIncapacitated(client) && !bPreventValveSwitch[client] && GetSlotFromWeaponId(wep) != GetSlotFromWeaponId(wepname)) {
		if (IsInDropping(weapon)) {	
			//PrintToChatAll("%N 切換藥丸!", client);
			bCantSwitchHealth[client] = true;
			RequestFrame(DelaySwitchHealth, client);
			return Plugin_Continue;
		}

		bCantSwitchSecondary[client] = true;
		RequestFrame(DelaySwitchSecondary, client);

		//PrintToChatAll("%N 撿起武器!", client);
		SDKHook(client, SDKHook_PostThinkPost, OnPostThinkPost);
	}
	return Plugin_Continue;
}

Action WeaponDrop(int client, int weapon)
{
	int active_weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	
	// Check if Player is Alive/Incapped and just dropped his secondary for a different one
	if (!IsPlayerIncapacitated(client) && IsPlayerAlive(client)) {
		if (weapon == active_weapon) {
			bPreventValveSwitch[client] = true;
			RequestFrame(DelayValveSwitch, client);
		}
	}
	return Plugin_Continue;
}


/* ---------------------------------
//                                 |
//       Dualies Workaround        |
//                                 |
// -------------------------------*/
bool IsSwitchingToDualCase(int client, int weapon)
{
	if (!IsValidEdict(weapon))
		return false;
	
	static char clsname[64];
	if (!GetEdictClassname(weapon, clsname, sizeof clsname))
		return false;
	
	if (clsname[0] != 'w')
		return false;
	
	if (strcmp(clsname[6], "_spawn") == 0)
	{
		if (GetEntProp(weapon, Prop_Send, "m_weaponID") != 1) // WEPID_PISTOL
			return false;
	}
	else if (strncmp(clsname[6], "_pistol", 7) != 0)
	{
		return false;
	}
	
	int secondary = GetPlayerWeaponSlot(client, 1);
	if (secondary == -1)
		return false;
	
	if (!GetEdictClassname(secondary, clsname, sizeof clsname))
		return false;
	
	return strcmp(clsname, "weapon_pistol") == 0 && !GetEntProp(secondary, Prop_Send, "m_hasDualWeapons");
}

MRESReturn DTR_OnEquipSecondWeapon(int weapon, DHookReturn hReturn)
{
	int client = GetEntPropEnt(weapon, Prop_Send, "m_hOwner");
	if (client == -1 || !IsClientInGame(client))
		return MRES_Ignored;
	
	if (~iSwitchFlags[client] & FLAGS_SWITCH_WEAPONS)
		return MRES_Ignored;
	
	if (!IsSwitchingToDualCase(client, weapon))
		return MRES_Ignored;
	
	g_hPatch.Enable();
	return MRES_Ignored;
}

MRESReturn DTR_OnEquipSecondWeapon_Post(int weapon, DHookReturn hReturn)
{
	g_hPatch.Disable();
	return MRES_Ignored;
}

// prevent setting viewmodel and next attack time
MRESReturn DTR_OnRemoveSecondWeapon_Ev(int weapon, DHookReturn hReturn)
{
	if (!GetEntProp(weapon, Prop_Send, "m_hasDualWeapons"))
		return MRES_Ignored;
	
	int client = GetEntPropEnt(weapon, Prop_Send, "m_hOwner");
	if (client == -1 || !IsClientInGame(client))
		return MRES_Ignored;
	
	int active_weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (active_weapon == -1 || active_weapon == weapon)
		return MRES_Ignored;
	
	if (~iSwitchFlags[client] & FLAGS_SWITCH_WEAPONS)
		return MRES_Ignored;
	
	SetEntProp(weapon, Prop_Send, "m_isDualWielding", 0);
	SetEntProp(weapon, Prop_Send, "m_hasDualWeapons", 0);
	
	int clip = GetEntProp(weapon, Prop_Send, "m_iClip1");
	SetEntProp(weapon, Prop_Send, "m_iClip1", clip / 2);
	
	hReturn.Value = 1;
	return MRES_Supercede;
}

/* ---------------------------------
//                                 |
//        Stocks, Functions        |
//                                 |
// -------------------------------*/
stock bool QuerySwitchCookie(int client, int &val)
{
	char buffer[8] = "";
	g_hSwitchCookie.Get(client, buffer, sizeof(buffer));
	if (strlen(buffer) > 0)
	{
		val = StringToInt(buffer);
		return true;
	}
	
	return false;
}

void SetSwitchCookie(int client, int val)
{
	char buffer[8];
	IntToString(val, buffer, sizeof(buffer));
	g_hSwitchCookie.Set(client, buffer);
}

void HookValidClient(int client, bool Hook)
{
	if (Hook) {
		SDKHook(client, SDKHook_WeaponCanSwitchTo, WeaponCanSwitchTo);
		SDKHook(client, SDKHook_WeaponEquip, WeaponEquip);
		SDKHook(client, SDKHook_WeaponDrop, WeaponDrop);
	} else {
		SDKUnhook(client, SDKHook_WeaponCanSwitchTo, WeaponCanSwitchTo);
		SDKUnhook(client, SDKHook_WeaponEquip, WeaponEquip);
		SDKUnhook(client, SDKHook_WeaponDrop, WeaponDrop);
	}
}

int IsInDropping(int weapon)
{
	static int iOffs_m_dropTimer = -1;
	if (iOffs_m_dropTimer == -1)
	{
		iOffs_m_dropTimer = FindSendPropInfo("CTerrorWeapon", "m_swingTimer") + 580;
	}
	
	return GetGameTime() <= GetEntDataFloat(weapon, iOffs_m_dropTimer + 8);
}

bool IsPlayerIncapacitated(int client)
{
	return view_as<bool>(GetEntProp(client, Prop_Send, "m_isIncapacitated", 1));
}

/* ---------------------------------
//                                 |
//          Cvar Changes!          |
//                                 |
// -------------------------------*/
void SwitchCVarChanged(ConVar cvar, const char[] oldValue, const char[] newValue)
{
	SwitchFlags = cvar.IntValue;
}

void OnPostThinkPost(int client)
{
	int iAddonBits = GetEntProp(client, Prop_Send, "m_iAddonBits");

	if (iAddonBits != 0)
	{
		//Weapons.
		if ((iSwitchFlags[client] & FLAGS_SWITCH_WEAPONS) && bCantSwitchSecondary[client]) {
			iAddonBits &= ~AddonBits_L4D1_Slot1;
			SetEntProp(client, Prop_Send, "m_iAddonBits", iAddonBits); //fix weapon model display on clients back
		}
	}

	SDKUnhook(client, SDKHook_PostThinkPost, OnPostThinkPost);
}