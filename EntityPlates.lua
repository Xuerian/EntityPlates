-- ------------------------------------------
-- Entity Plates
--   by: John Su
--   modifications by: TuffGhost
-- ------------------------------------------
require "unicode";
require "math";
require "table";
require "./EntityRules";
require "lib/lib_Callback2";
require "lib/lib_MapMarker";
require "lib/lib_Liaison";
require "lib/lib_math";
require "lib/lib_MultiArt";
require "lib/lib_HudManager";
require "lib/lib_Vector";

-- ------------------------------------------
-- CONSTANTS
-- ------------------------------------------
local MAP_INFO_GROUP = Component.GetWidget("map_info");
local MAP_INFO_VITALS = Component.GetWidget("shadow_vitals");
local w_MAP_INFO;
local SPECTATOR_TEAM = "1";

-- for use in entity suppression
local SUPPRESS_HUD = "hud";	-- don't show HUD plate
local SUPPRESS_MAP = "map";	-- don't show radar/map entries
local SUPPRESS_ALL = "all";	-- don't show ANYTHING

local IGNORE_TYPES = {
	["loot"]		= true,
	["sin_object"]	= true,
	["Globe"]		= true,
}

local ARES_ITEMS = {
	["Accord Datapad"]				= true,
	["Crashed Thumper Part"]		= true,
	["Crystite Core"]				= true,
	["Disruption Defuse Pin Black"]	= true,
	["Disruption Defuse Pin Red"]	= true,
	["Disruption Defuse Pin White"]	= true,
	["Drill Parts"]					= true,
	["Medical Supplies"]			= true,
	["Tainted Crystite"]			= true,
}

local PRIORITY_NONE = 0;	-- I don't care
local PRIORITY_LOW = 1;		-- deployables, npc's; things that are not urgent
local PRIORITY_MEDIUM = 2;	-- enemies, allies; combat significant
local PRIORITY_HIGH = 3;	-- squadmates

local PRIORITY_SETTINGS = {
	[PRIORITY_NONE]		= {cull_alpha=0, docks_to_edge=false},
	[PRIORITY_LOW]		= {cull_alpha=0, docks_to_edge=false},
	[PRIORITY_MEDIUM]	= {cull_alpha=0.8, docks_to_edge=false},
	[PRIORITY_HIGH]		= {cull_alpha=0.8, docks_to_edge=true},
}


local RELEASE_PLATE_FOCUS_DELAY = 1.5;

local MEDIMODES = {
	NONE		= false,
	MEDIC		= {patientType="character"},
	ENGINEER	= {patientType="deployable"},
}

local COLOR_DAMAGE = Component.LookupColor("damage");
local COLOR_HEALING = Component.LookupColor("healing");
local MIN_STANDBY_PLATES = 16;	-- try to keep at least this many plates in standby/recycling

-- ------------------------------------------
-- VARIABLES
-- ------------------------------------------
local w_RecycleBin = {};	-- recycle bin for PLATEs
local w_PLATES	= {};	-- w_PLATES[tostring(entityId)] = PLATE
local w_ToRecycle = {};	-- list of PLATEs to clean out
local d_suppressedEntities = {};	-- list of entityId's to ignore
local g_myId	= nil;	-- myself (or my spectatee)
local g_myTeamId = nil;	-- my team (or spectatee's)
local g_sinView	= false;
local g_ShowHud = true;
local g_spectating = false;
local g_spectating_follow = true;
local g_lastFocusedPlate = nil;
local g_focused_MARKER = nil;
local g_mediMode = MEDIMODES.NONE;	-- medic on the prowl, looking for injured allies
local g_maxPatients = 20;	-- max patients to show
local CYCLE_DisposePlates;
local CYCLE_MediModePulse;
local CYCLE_HighVisPulse;
local CB2_RecyclePlates = Callback2.Create();
local CB2_ReleaseFocusedPlate = Callback2.Create();
local g_is_challenge_ready = false;

local g_Loaded = false;
local g_doUpdateStyle = false;
local g_doUpdateLayout = false;
local g_doUpdateConfiguration = false;

-- ------------------------------------------
-- INTERFACE OPTIONS
-- ------------------------------------------
require "lib/lib_InterfaceOptions";

local io_Enabled = true;
local io_PlateAlpha = 1.0;
local io_ShadowAlpha = 0.8;

local io_PlateStyle = "modern";
local c_Modern = "modern";
local c_Beta = "beta";

local io_UseArchetypeIcon = false
local io_HideFullHealthbars = false;
local io_HideLevelsForNPCs = true;
local io_MinimizeDockedPlates = true;

local io_ShowTitles = "always";
local io_ShowLevels = "always";
local c_Always = "always";
local c_SinViewOnly = "sin_view_only";
local c_Never = "never";

local io_MediModeHealthThreshold = 1.0;
local io_MediModeMaxRange = 80;

local io_MediModeEngineer = "mine";
local c_AllDeployables = "all";
local c_MyDeployablesOnly = "mine";
local c_NoDeployables = "none";

local io_HighVisiblity = true;
local io_HighVisRanges = {
	["VENDORS"] = {label = "Vendors", range = 100},
	["GLIDER_PADS"] = {label = "Glider Pads", range = 100},
	["BATTLEFRAME_STATIONS"] = {label = "Battleframe Stations", range = 100},
	["ARES_ITEMS"] = {label = "ARES Mission Items", range = 100},
}

local io_RelationshipColors = {
	friendly	= Component.LookupColor("friendly").rgb,
	hostile		= Component.LookupColor("hostile").rgb,
	neutral		= Component.LookupColor("neutral").rgb,
	npc			= Component.LookupColor("npc").rgb,
	squad		= Component.LookupColor("squad").rgb,
	platoon		= Component.LookupColor("platoon").rgb,
	army		= Component.LookupColor("army").rgb,
	me			= Component.LookupColor("me").rgb,
};

local io_StageColors = {
	Component.LookupColor("con_grey").rgb,
	Component.LookupColor("con_green").rgb,
	Component.LookupColor("con_yellow").rgb,
	Component.LookupColor("con_red").rgb,
	Component.LookupColor("con_skull").rgb,
};

local io_ColorSettings = {
	name = "relationship",
	title = "relationship",
	level = "relationship",
	icon = "stage",
	health_bar = "stage",
};

local c_UseRelationshipColor = "relationship";
local c_UseStageColor = "stage";


do -- interface options
	InterfaceOptions.SaveVersion(1.27);
	InterfaceOptions.NotifyOnLoaded(true);

	InterfaceOptions.AddCheckBox({id="ENABLED", label_key="ENTITY_PLATES_ENABLED", default=io_Enabled})

	InterfaceOptions.AddChoiceMenu({id="PLATE_STYLE", label="Plate Style", default=io_PlateStyle});
		InterfaceOptions.AddChoiceEntry({menuId="PLATE_STYLE", label="Beta", val=c_Beta});
		InterfaceOptions.AddChoiceEntry({menuId="PLATE_STYLE", label="Modern", val=c_Modern});

	InterfaceOptions.AddSlider({id="PLATE_ALPHA", label="Plate Opacity", default=io_PlateAlpha, min=0, max=1, inc=0.01, format="%0.0f", multi=100, suffix="%"})
	InterfaceOptions.AddSlider({id="SHADOW_ALPHA", label="Shadow Opacity", default=io_ShadowAlpha, min=0, max=1, inc=0.01, format="%0.0f", multi=100, suffix="%"})

	InterfaceOptions.AddCheckBox({id="USE_ARCHETYPE_ICON", label="Use Archetype Frame Icon", default=io_UseArchetypeIcon});

	InterfaceOptions.AddChoiceMenu({id="SHOW_TITLES", label="Show Titles", default=io_ShowTitles});
		InterfaceOptions.AddChoiceEntry({menuId="SHOW_TITLES", label="Always", val=c_Always});
		InterfaceOptions.AddChoiceEntry({menuId="SHOW_TITLES", label="SIN View Only", val=c_SinViewOnly});
		InterfaceOptions.AddChoiceEntry({menuId="SHOW_TITLES", label="Never", val=c_Never});

	InterfaceOptions.AddChoiceMenu({id="SHOW_LEVELS", label="Show Levels", default=io_ShowLevels});
		InterfaceOptions.AddChoiceEntry({menuId="SHOW_LEVELS", label="Always", val=c_Always});
		InterfaceOptions.AddChoiceEntry({menuId="SHOW_LEVELS", label="SIN View Only", val=c_SinViewOnly});
		InterfaceOptions.AddChoiceEntry({menuId="SHOW_LEVELS", label="Never", val=c_Never});
	
	InterfaceOptions.AddCheckBox({id="MINIMIZE_DOCKED_PLATES", label="Hide Titles/Levels For Docked Plates", default=io_MinimizeDockedPlates})
		
	InterfaceOptions.AddCheckBox({id="HIDE_LEVELS_FOR_NPCS", label="Hide Levels For NPCs", default=io_HideLevelsForNPCs})
	InterfaceOptions.AddCheckBox({id="HIDE_FULL_HEALTHBARS", label="Hide Full Health Bars", default=io_HideFullHealthbars})

	InterfaceOptions.StartGroup({id="MEDIMODE_SETTINGS", label="MediMode Settings"});
		InterfaceOptions.AddChoiceMenu({id="MEDIMODE_ENGINEER", label="Enable Engineer's MediMode For", default=io_MediModeEngineer});
			InterfaceOptions.AddChoiceEntry({menuId="MEDIMODE_ENGINEER", label="All Deployables", val=c_AllDeployables});
			InterfaceOptions.AddChoiceEntry({menuId="MEDIMODE_ENGINEER", label="My Deployables Only", val=c_MyDeployablesOnly});
			InterfaceOptions.AddChoiceEntry({menuId="MEDIMODE_ENGINEER", label="No Deployables (Disable)", val=c_NoDeployables});
		InterfaceOptions.AddSlider({id="MEDIMODE_HEALTH_THRESHOLD", label="Health Threshold", default=io_MediModeHealthThreshold, min=0, max=1, inc=0.01, format="%0.0f", multi=100, suffix="%"})
		InterfaceOptions.AddSlider({id="MEDIMODE_MAX_RANGE", label="Maximum Range", default=io_MediModeMaxRange, min=0, max=150, inc=1, suffix="m"})
	InterfaceOptions.StopGroup();

	InterfaceOptions.StartGroup({id="HIGH_VISIBILITY", label="Increased Visibility", checkbox=true, default=io_HighVisiblity});
		InterfaceOptions.AddSlider({id="HIGH_VIS_ARES_ITEMS", label=io_HighVisRanges["ARES_ITEMS"].label, default=io_HighVisRanges["ARES_ITEMS"].range, min=0, inc=10, max=200, suffix="m"})
		InterfaceOptions.AddSlider({id="HIGH_VIS_BATTLEFRAME_STATIONS", label=io_HighVisRanges["BATTLEFRAME_STATIONS"].label, default=io_HighVisRanges["BATTLEFRAME_STATIONS"].range, min=0, inc=10, max=200, suffix="m"})
		InterfaceOptions.AddSlider({id="HIGH_VIS_GLIDER_PADS", label=io_HighVisRanges["GLIDER_PADS"].label, default=io_HighVisRanges["GLIDER_PADS"].range, min=0, inc=10, max=200, suffix="m"})
		InterfaceOptions.AddSlider({id="HIGH_VIS_VENDORS", label=io_HighVisRanges["VENDORS"].label, default=io_HighVisRanges["VENDORS"].range, min=0, inc=10, max=200, suffix="m"})
	InterfaceOptions.StopGroup();

	InterfaceOptions.StartGroup({label="Plate Color Settings", subtab={"Colors"}});
		InterfaceOptions.AddChoiceMenu({id="COLOR_SETTINGS_NAME", label="Name", default=io_ColorSettings.name, subtab={"Colors"}});
			InterfaceOptions.AddChoiceEntry({menuId="COLOR_SETTINGS_NAME", label="Use Relationship Color", val=c_UseRelationshipColor, subtab={"Colors"}});
			InterfaceOptions.AddChoiceEntry({menuId="COLOR_SETTINGS_NAME", label="Use Difficulty Color", val=c_UseStageColor, subtab={"Colors"}});

		InterfaceOptions.AddChoiceMenu({id="COLOR_SETTINGS_TITLE", label="Title", default=io_ColorSettings.title, subtab={"Colors"}});
			InterfaceOptions.AddChoiceEntry({menuId="COLOR_SETTINGS_TITLE", label="Use Relationship Color", val=c_UseRelationshipColor, subtab={"Colors"}});
			InterfaceOptions.AddChoiceEntry({menuId="COLOR_SETTINGS_TITLE", label="Use Difficulty Color", val=c_UseStageColor, subtab={"Colors"}});

		InterfaceOptions.AddChoiceMenu({id="COLOR_SETTINGS_LEVEL", label="Level", default=io_ColorSettings.level, subtab={"Colors"}});
			InterfaceOptions.AddChoiceEntry({menuId="COLOR_SETTINGS_LEVEL", label="Use Relationship Color", val=c_UseRelationshipColor, subtab={"Colors"}});
			InterfaceOptions.AddChoiceEntry({menuId="COLOR_SETTINGS_LEVEL", label="Use Difficulty Color", val=c_UseStageColor, subtab={"Colors"}});

		InterfaceOptions.AddChoiceMenu({id="COLOR_SETTINGS_ICON", label="Icon", default=io_ColorSettings.icon, subtab={"Colors"}});
			InterfaceOptions.AddChoiceEntry({menuId="COLOR_SETTINGS_ICON", label="Use Relationship Color", val=c_UseRelationshipColor, subtab={"Colors"}});
			InterfaceOptions.AddChoiceEntry({menuId="COLOR_SETTINGS_ICON", label="Use Difficulty Color", val=c_UseStageColor, subtab={"Colors"}});

		InterfaceOptions.AddChoiceMenu({id="COLOR_SETTINGS_HEALTH_BAR", label="Health Bar", default=io_ColorSettings.health_bar, subtab={"Colors"}});
			InterfaceOptions.AddChoiceEntry({menuId="COLOR_SETTINGS_HEALTH_BAR", label="Use Relationship Color", val=c_UseRelationshipColor, subtab={"Colors"}});
			InterfaceOptions.AddChoiceEntry({menuId="COLOR_SETTINGS_HEALTH_BAR", label="Use Difficulty Color", val=c_UseStageColor, subtab={"Colors"}});
	InterfaceOptions.StopGroup({subtab={"Colors"}});

	InterfaceOptions.StartGroup({label="Relationship Colors", subtab={"Colors"}});
		InterfaceOptions.AddColorPicker({id="COLOR_PICKER_RELATIONSHIP_FRIENDLY", label="Friendly", default={tint=io_RelationshipColors.friendly}, subtab={"Colors"}});
		InterfaceOptions.AddColorPicker({id="COLOR_PICKER_RELATIONSHIP_HOSTILE", label="Hostile", default={tint=io_RelationshipColors.hostile}, subtab={"Colors"}});
		InterfaceOptions.AddColorPicker({id="COLOR_PICKER_RELATIONSHIP_NEUTRAL", label="Neutral", default={tint=io_RelationshipColors.neutral}, subtab={"Colors"}});
		InterfaceOptions.AddColorPicker({id="COLOR_PICKER_RELATIONSHIP_NPC", label="NPC", default={tint=io_RelationshipColors.npc}, subtab={"Colors"}});
		InterfaceOptions.AddColorPicker({id="COLOR_PICKER_RELATIONSHIP_SQUAD", label="Squad", default={tint=io_RelationshipColors.squad}, subtab={"Colors"}});
		InterfaceOptions.AddColorPicker({id="COLOR_PICKER_RELATIONSHIP_PLATOON", label="Platoon", default={tint=io_RelationshipColors.platoon}, subtab={"Colors"}});
		InterfaceOptions.AddColorPicker({id="COLOR_PICKER_RELATIONSHIP_ARMY", label="Army", default={tint=io_RelationshipColors.army}, subtab={"Colors"}});
		InterfaceOptions.AddColorPicker({id="COLOR_PICKER_RELATIONSHIP_ME", label="Me", default={tint=io_RelationshipColors.me}, subtab={"Colors"}});
	InterfaceOptions.StopGroup({subtab={"Colors"}});

	InterfaceOptions.StartGroup({label="Difficulty Colors", subtab={"Colors"}});
		InterfaceOptions.AddColorPicker({id="COLOR_PICKER_STAGE_1", label="Stage 1", default={tint=io_StageColors[1]}, subtab={"Colors"}});
		InterfaceOptions.AddColorPicker({id="COLOR_PICKER_STAGE_2", label="Stage 2", default={tint=io_StageColors[2]}, subtab={"Colors"}});
		InterfaceOptions.AddColorPicker({id="COLOR_PICKER_STAGE_3", label="Stage 3", default={tint=io_StageColors[3]}, subtab={"Colors"}});
		InterfaceOptions.AddColorPicker({id="COLOR_PICKER_STAGE_4", label="Stage 4", default={tint=io_StageColors[4]}, subtab={"Colors"}});
		InterfaceOptions.AddColorPicker({id="COLOR_PICKER_STAGE_5", label="Stage 5", default={tint=io_StageColors[5]}, subtab={"Colors"}});
	InterfaceOptions.StopGroup({subtab={"Colors"}});
end

function OnOptionChange(id, val)
	if id == "ENABLED" then
		io_Enabled = val;
		for _, PLATE in pairs(w_PLATES) do
			PLATE.GROUP:Show(io_Enabled);
		end
		SetOptionsAvailability();

	elseif id == "PLATE_STYLE" then
		io_PlateStyle = val;
		g_doUpdateStyle = true;

		-- make sure vitals are aligned correctly in map mode
		if (io_PlateStyle == c_Modern) then
			MAP_INFO_VITALS:SetDims("left:50%+42t; width:80; height:7; top:30;");
		elseif (io_PlateStyle == c_Beta) then
			MAP_INFO_VITALS:SetDims("left:50%+42t; width:60; height:6; top:30;");
		end

	elseif id == "PLATE_ALPHA" then
		io_PlateAlpha = val;
		for _, PLATE in pairs(w_PLATES) do
			PLATE.GROUP:SetParam("alpha", io_PlateAlpha);
		end

	elseif id == "SHADOW_ALPHA" then
		io_ShadowAlpha = val;
		for _, PLATE in pairs(w_PLATES) do
			for _, SHADOW in pairs(PLATE.SHADOWS) do
				SHADOW:SetParam("alpha", io_ShadowAlpha);
			end
		end

	elseif id == "USE_ARCHETYPE_ICON" then
		io_UseArchetypeIcon = val;
		for _,PLATE in pairs(w_PLATES) do
			if (PLATE.icon) then
				if (PLATE.icon.use_icon) then
					SetIconVisuals(PLATE.MIN_PLATE.ART, PLATE.icon);
					SetIconVisuals(PLATE.MIN_PLATE.SHADOW, PLATE.icon);
					SetIconVisuals(PLATE.FULL_PLATE.ICON.ART, PLATE.icon);
					SetIconVisuals(PLATE.FULL_PLATE.ICON.SHADOW, PLATE.icon);
				end
				if (PLATE.MAPMARKER and not PLATE.MAPMARKER.texture_override) then
					SetIconVisuals(PLATE.MAPMARKER:GetIcon(), PLATE.icon);
				end
			end
			if (w_MAP_INFO) then
				SetIconVisuals(w_MAP_INFO.ICON, w_MAP_INFO.rules);
			end
		end

	elseif id == "SHOW_TITLES" then
		io_ShowTitles = val;
		g_doUpdateConfiguration = true;

	elseif id == "SHOW_LEVELS" then
		io_ShowLevels = val;
		g_doUpdateConfiguration = true;

	elseif id == "HIDE_LEVELS_FOR_NPCS" then
		io_HideLevelsForNPCs = val;
		g_doUpdateConfiguration = true;

	elseif id == "HIDE_FULL_HEALTHBARS" then
		io_HideFullHealthbars = val;
		g_doUpdateConfiguration = true;

	elseif id == "MINIMIZE_DOCKED_PLATES" then
		io_MinimizeDockedPlates = val;
		g_doUpdateConfiguration = true;

	elseif id == "MEDIMODE_ENGINEER" then
		io_MediModeEngineer = val;
		SelectMediMode();

	elseif id == "MEDIMODE_HEALTH_THRESHOLD" then
		io_MediModeHealthThreshold = val;

	elseif id == "MEDIMODE_MAX_RANGE" then
		io_MediModeMaxRange = val;

	elseif id == "HIGH_VISIBILITY" then
		io_HighVisiblity = val;
		if (io_Enabled and io_HighVisiblity) then
			CYCLE_HighVisPulse:Run(1);
		else
			CYCLE_HighVisPulse:Stop();
		end
		g_doUpdateConfiguration = true;

	elseif (unicode.sub(id, 1, 8) == "HIGH_VIS") then
		local idx = unicode.sub(id, 10);
		io_HighVisRanges[idx].range = val;
		if (val == 0) then
			InterfaceOptions.UpdateLabel(id, io_HighVisRanges[idx].label .. " (Disabled)");
		else
			InterfaceOptions.UpdateLabel(id, io_HighVisRanges[idx].label);
		end
		
	elseif (unicode.sub(id, 1, 14) == "COLOR_SETTINGS") then
		io_ColorSettings[unicode.lower(unicode.sub(id, 16))] = val;
		g_doUpdateLayout = true;

	elseif (unicode.sub(id, 1, 25) == "COLOR_PICKER_RELATIONSHIP") then
		io_RelationshipColors[unicode.lower(unicode.sub(id, 27))] = val.tint;
		g_doUpdateLayout = true;

	elseif (unicode.sub(id, 1, 18) == "COLOR_PICKER_STAGE") then
		io_StageColors[tonumber(unicode.sub(id, 20))] = val.tint;
		g_doUpdateLayout = true;

	elseif (id == "__LOADED") then
		-- finished startup
		g_Loaded = true;
	end

	if (g_Loaded) then
		if (g_doUpdateStyle) then
			for _,PLATE in pairs(w_PLATES) do
				PLATE.vitals = {};
				PLATE_CreateElements(PLATE);
				PLATE_UpdateInfo(PLATE);
				PLATE_UpdateVitals(PLATE, 0);
				PLATE_UpdateStatus(PLATE, 0);
				PLATE_UpdateConfiguration(PLATE, 0.1);
			end

		elseif (g_doUpdateLayout) then
			for _,PLATE in pairs(w_PLATES) do
				PLATE_UpdateLayout(PLATE);
				PLATE_UpdateConfiguration(PLATE, 0.1);
			end

		elseif (g_doUpdateConfiguration) then
			for _,PLATE in pairs(w_PLATES) do
				PLATE_UpdateConfiguration(PLATE, 0.1);
			end
		end

		g_doUpdateStyle = false;
		g_doUpdateLayout = false;
		g_doUpdateConfiguration = false;
	end
end

function SetOptionsAvailability()
	InterfaceOptions.EnableOption("PLATE_STYLE", io_Enabled);
	InterfaceOptions.EnableOption("PLATE_ALPHA", io_Enabled);
	InterfaceOptions.EnableOption("SHADOW_ALPHA", io_Enabled);
	InterfaceOptions.EnableOption("USE_ARCHETYPE_ICON", io_Enabled);

	InterfaceOptions.EnableOption("SHOW_TITLES", io_Enabled);
	InterfaceOptions.EnableOption("SHOW_LEVELS", io_Enabled);
	InterfaceOptions.EnableOption("HIDE_LEVELS_FOR_NPCS", io_Enabled);
	InterfaceOptions.EnableOption("HIDE_FULL_HEALTHBARS", io_Enabled);
	InterfaceOptions.EnableOption("MINIMIZE_DOCKED_PLATES", io_Enabled);

	InterfaceOptions.EnableOption("MEDIMODE_SETTINGS", io_Enabled);
	InterfaceOptions.EnableOption("MEDIMODE_ENGINEER", io_Enabled);
	InterfaceOptions.EnableOption("MEDIMODE_HEALTH_THRESHOLD", io_Enabled);
	InterfaceOptions.EnableOption("MEDIMODE_MAX_RANGE", io_Enabled);

	InterfaceOptions.EnableOption("HIGH_VISIBILITY", io_Enabled);
	InterfaceOptions.EnableOption("HIGH_VIS_ARES_ITEMS", io_Enabled);
	InterfaceOptions.EnableOption("HIGH_VIS_BATTLEFRAME_STATIONS", io_Enabled);
	InterfaceOptions.EnableOption("HIGH_VIS_GLIDER_PADS", io_Enabled);
	InterfaceOptions.EnableOption("HIGH_VIS_VENDORS", io_Enabled);

	-- colors are used for the map markers too, so I'll just leave them enabled I guess
	-- InterfaceOptions.EnableOption("COLOR_SETTINGS_NAME", io_Enabled);
	-- InterfaceOptions.EnableOption("COLOR_SETTINGS_TITLE", io_Enabled);
	-- InterfaceOptions.EnableOption("COLOR_SETTINGS_LEVEL", io_Enabled);
	-- InterfaceOptions.EnableOption("COLOR_SETTINGS_ICON", io_Enabled);
	-- InterfaceOptions.EnableOption("COLOR_SETTINGS_HEALTH_BAR", io_Enabled);

	-- InterfaceOptions.EnableOption("COLOR_PICKER_RELATIONSHIP_FRIENDLY", io_Enabled);
	-- InterfaceOptions.EnableOption("COLOR_PICKER_RELATIONSHIP_HOSTILE", io_Enabled);
	-- InterfaceOptions.EnableOption("COLOR_PICKER_RELATIONSHIP_NEUTRAL", io_Enabled);
	-- InterfaceOptions.EnableOption("COLOR_PICKER_RELATIONSHIP_NPC", io_Enabled);
	-- InterfaceOptions.EnableOption("COLOR_PICKER_RELATIONSHIP_SQUAD", io_Enabled);
	-- InterfaceOptions.EnableOption("COLOR_PICKER_RELATIONSHIP_PLATOON", io_Enabled);
	-- InterfaceOptions.EnableOption("COLOR_PICKER_RELATIONSHIP_ARMY", io_Enabled);
	-- InterfaceOptions.EnableOption("COLOR_PICKER_RELATIONSHIP_ME", io_Enabled);

	-- InterfaceOptions.EnableOption("COLOR_PICKER_STAGE_1", io_Enabled);
	-- InterfaceOptions.EnableOption("COLOR_PICKER_STAGE_2", io_Enabled);
	-- InterfaceOptions.EnableOption("COLOR_PICKER_STAGE_3", io_Enabled);
	-- InterfaceOptions.EnableOption("COLOR_PICKER_STAGE_4", io_Enabled);
	-- InterfaceOptions.EnableOption("COLOR_PICKER_STAGE_5", io_Enabled);

	if (io_Enabled and io_HighVisiblity) then
		CYCLE_HighVisPulse:Run(1);
	else
		CYCLE_HighVisPulse:Stop();
	end
end

-- ------------------------------------------
-- EVENT FUNCTIONS
-- ------------------------------------------
function OnComponentLoad()
	InterfaceOptions.SetCallbackFunc(OnOptionChange, "TuffPlates")
	g_myTeamId = SPECTATOR_TEAM;

	MapInfo_Create();

	CB2_RecyclePlates:Bind(RecyclePlates);
	CB2_ReleaseFocusedPlate:Bind(ReleaseFocusedPlate);

	CYCLE_MediModePulse = Callback2.CreateCycle(MediModePulse);
	CYCLE_HighVisPulse = Callback2.CreateCycle(HighVisPulse);
	CYCLE_DisposePlates = Callback2.CreateCycle(DisposePlates);
	CYCLE_DisposePlates:Run(20);	-- do a clean up every 20 seconds

	Liaison.BindMessage("dock_groupmates", function(data)
		OnDockGroupMates(data == "true");
	end);

	HudManager.BlacklistReasons({"reticle_scope"})
	HudManager.BindOnShow(OnHudShow)
end

function OnPlayerReady()
	g_myId = Player.GetTargetId();
	
	-- destroy own PLATE, if exists
	local PLATE = w_PLATES[tostring(g_myId)];
	if (PLATE) then
		PLATE_RecycleOut(PLATE);
	end
	
	OnTeamChanged();
	OnBattleframeChanged();
end

function OnHudShow(show, dur)
	g_ShowHud = show;

	if (g_ShowHud) then
		if (g_lastFocusedPlate) then
			PLATE_OnLostFocus(g_lastFocusedPlate);
		end

		if (g_focused_MARKER) then
			g_focused_MARKER:DispatchEvent("OnLostFocus");
		end
	end

	for _,PLATE in pairs(w_PLATES) do
		PLATE_UpdateConfiguration(PLATE, dur);
	end
end

function OnTeamChanged()
	local info = Game.GetTargetInfo(g_myId);

	if (info) then
		g_myTeamId = Game.GetTargetInfo(g_myId).teamId;
	else
		g_myTeamId = SPECTATOR_TEAM;
	end

	for _,PLATE in pairs(w_PLATES) do
		PLATE_UpdateInfo(PLATE);
		PLATE_UpdateConfiguration(PLATE, 0.1);
	end
end

function OnLevelChanged()
	for _,PLATE in pairs(w_PLATES) do
		PLATE_UpdateInfo(PLATE);
		PLATE_UpdateConfiguration(PLATE, 0.1);
	end
end

function OnBattleframeChanged()
	SelectMediMode();
end

function OnHideEntity(args)	
	local tag = tostring(args.entityId);
	local hide = args.hide;	-- "all"/true, "map", "hud", or false
	local PLATE = GetPlateFromArgs(args);

	if (hide) then
		d_suppressedEntities[tag] = hide;
		if (PLATE) then
			if (hide == SUPPRESS_ALL or hide == true) then
				OnEntityLost({entityId=args.entityId, timeout=1});
			else
				PLATE_UpdateVisibility(PLATE);
			end
		end
	else
		d_suppressedEntities[tag] = nil;
		if (PLATE) then
			PLATE_UpdateVisibility(PLATE);
		else
			local info = Game.GetTargetInfo(args.entityId);
			if (info) then
				OnEntityAvailable({entityId=args.entityId, type=info.type});
			end
		end
	end
end

function OnEntityAvailable(args)
	-- args = {entityId, type}
	local tag = tostring(args.entityId);
	
	-- ignore self, IGNORE_TYPES, and entities suppressed by other UI
	if ((g_spectating_follow and args.entityId == g_myId)
		or IGNORE_TYPES[args.type]
		or d_suppressedEntities[tag]) then
		return;
	end
	
	-- put the dying predecessor into the recycle bin for immediate use, if it exists
	local PLATE = w_ToRecycle[tag];
	if (PLATE) then
		PLATE_RecycleOut(PLATE);
	end
	
	PLATE = GetPlateFromArgs(args);
	if (not PLATE) then
		PLATE = PrepareCleanPLATE(args.entityId);
	end

	PLATE_UpdateInfo(PLATE);
	PLATE_UpdateVitals(PLATE, 0);
	PLATE_UpdateStatus(PLATE, 0);
	PLATE_UpdateConfiguration(PLATE, 0.1);
end

function OnEntityLost(args)
	-- args = {entityId[, timeout]}
	local PLATE = GetPlateFromArgs(args);
	if (not PLATE) then
		return;	-- none of our concern
	end

	if (args.timeout) then
		PLATE_SlowKill(PLATE, 0.5);
	elseif (PLATE and not PLATE.kill_start) then
		PLATE_SlowKill(PLATE, 1.0);
	end
end

function OnHitTarget(args)
	if (not args.damage) then
		return;
	end

	local PLATE = GetPlateFromArgs(args);
	if (PLATE) then
		PLATE_AnimateHit(PLATE, args.damage, 0.4);
	end
end

function OnSimulatedHit(args)
	local PLATE = GetPlateFromArgs(args);
	if (PLATE) then
		local vitals = PLATE.vitals;
		local pct = math.ceil(vitals.health_pct*100);
		local overfill_pct = math.max(0, pct-100);
		local max_hp =  PLATE.vitals.MaxHealth * ( overfill_pct + 100 );

		local dur = math.max( 0.15, args.health_change / max_hp * 5 );
		local delay = math.max( 0.1,args.health_change / max_hp * 0.6 );
		PLATE.FULL_PLATE.VITALS.FLASH:SetParam( "alpha", 1 );
		PLATE.FULL_PLATE.VITALS.FLASH:ParamTo( "alpha", 0, dur, delay, "ease-in" );
	end
end

function OnEntityVitalsChanged(args)
	-- args = {entityId}
	local PLATE = GetPlateFromArgs(args);
	if (PLATE) then
		PLATE_UpdateVitals(PLATE, 0.2);
	end
end

function OnEntityStatusChanged(args)
	-- args = {entityId}
	local PLATE = GetPlateFromArgs(args);
	if (PLATE) then
		PLATE_UpdateStatus(PLATE, 0.2);
		PLATE_UpdateConfiguration(PLATE, 0.2);
	end
end

function OnEntityInfoChanged(args)
	-- args = {entityId}
	local PLATE = GetPlateFromArgs(args);
	if (PLATE) then
		PLATE_UpdateInfo(PLATE);
		PLATE_UpdateConfiguration(PLATE, 0.2);
	end
end

function OnEntityFocus(args)
	if (args.entityId) then
		local PLATE = GetPlateFromArgs(args);
		if (PLATE) then
			PLATE_OnGotFocus(PLATE);
		end
	end
end

function OnFullView(args)
	g_sinView = args.sinView;

	if g_sinView then
		System.PlaySound("Play_UI_SINView_Mode");		
	else
		System.PlaySound("Stop_UI_SINView_Mode");
	end

	for _,PLATE in pairs(w_PLATES) do
		-- only reveals entities with enough importance to have an icon
		PLATE_UpdateConfiguration(PLATE, 0.2);
	end
end

function ScopeInEntity( entityId )
	local info = Game.GetTargetInfo(entityId);
	if (info) then
		OnEntityAvailable({entityId=entityId, type=info.type});
	end
end

function ScopeOutEntity( entityId )
	PLATE_SlowKill(GetPlateFromArgs({entityId=entityId}), 0.5);
end

function OnSpectatorMode( args )
	g_spectating = Player.IsSpectating();
	if (g_spectating) then
		--g_passiveFocusMin = PRIORITY_CLASS.player;

		-- handle overhead and camera views
		if( args.follow or args.killshot ) then
			g_spectating_follow = true;
			if( g_myId ) then
				ScopeOutEntity(g_myId)
			end
		elseif( args.overhead or args.static or args.flycam or args.custom ) then
			-- when not following a player, make all player aags display
			g_spectating_follow = false;

			if (g_myId) then
				ScopeInEntity(g_myId)
			end
		end
	else
		g_spectating_follow = true;
		--g_passiveFocusMin = PRIORITY_CLASS.squad;
	end
end

function OnSpectatePlayer(arg)
	if (g_spectating) then
		local prev_ent = g_myId;
		g_myId = arg.entityId;
		if (not g_myId) then
			g_myId = Player.GetTargetId();
		end
		--OnTeamChanged();

		-- "scope in" the previous local entity
		if (prev_ent) then
			ScopeInEntity(prev_ent)
		end

		-- "scope out" the new local entity
		if (g_myId and g_spectating_follow) then
			ScopeOutEntity(g_myId)
		end
	end
end

function PLATE_OnGotFocus(PLATE)
	PLATE.focus = true;
	PLATE_UpdateConfiguration(PLATE, 0.2);

	if (PLATE ~= g_lastFocusedPlate) then
		if (g_lastFocusedPlate) then
			-- quickly fade out previously focused plate
			g_lastFocusedPlate.focus = false;
			CB2_ReleaseFocusedPlate:Execute();
		end
		g_lastFocusedPlate = PLATE;
	else
		if (CB2_ReleaseFocusedPlate:Pending()) then
			-- cancel fade-out of this plate because we want it to remain focused
			CB2_ReleaseFocusedPlate:Cancel();
		end
	end
end

function PLATE_OnLostFocus(PLATE)
	if (PLATE.focus and PLATE == g_lastFocusedPlate) then
		PLATE.focus = false;

		if (CB2_ReleaseFocusedPlate:Pending()) then
			CB2_ReleaseFocusedPlate:Cancel();
		end
		CB2_ReleaseFocusedPlate:Schedule(RELEASE_PLATE_FOCUS_DELAY);
	end
end

function PLATE_OnEdgeTrip(PLATE, args)
	PLATE.docked = not args.onscreen;

	if (PLATE.minimized ~= PLATE.docked) then
		PLATE.minimized = PLATE.docked;
		PLATE_UpdateConfiguration(PLATE, 0.2);
	end
end

function OnDockGroupMates(will_dock)
	-- called from GroupUI component ("dock_groupmates")
	PRIORITY_SETTINGS[PRIORITY_HIGH].docks_to_edge = will_dock;
	-- update all plates at this priority
	for _,PLATE in pairs(w_PLATES) do
		if (PLATE.priority == PRIORITY_HIGH) then
			PLATE_UpdateConfiguration(PLATE, 0.1);
		end
	end
end

-- ------------------------------------------
-- GENERAL FUNCTIONS
-- ------------------------------------------
function GetPlateFromArgs(args)
	local tag;
	if (args.frame) then
		tag = args.frame:GetName();
	elseif (args.entityId) then
		tag = tostring(args.entityId);
	else
		error("cannot find plate from args:"..tostring(args));
	end
	return w_PLATES[tag];
end

function RecyclePlates()
	-- recycles inactive plates for re-use later
	local soonest_recycle = nil;
	local nextToRecycle = {};
	for idx,PLATE in pairs(w_ToRecycle) do
		local remaining_dur = PLATE.kill_dur - System.GetElapsedTime(PLATE.kill_start);
		if (remaining_dur <= 0) then
			PLATE_RecycleOut(PLATE);
		else
			nextToRecycle[idx] = PLATE;
			if (not soonest_recycle or remaining_dur < soonest_recycle) then
				soonest_recycle = remaining_dur;
			end
		end
	end
	w_ToRecycle = nextToRecycle;
	if (soonest_recycle) then
		CB2_RecyclePlates:Schedule(soonest_recycle+.1);
	end
end

function DisposePlates()
	-- discards excess plates from the recycling bin to free up memory
	local to_dispose = #w_RecycleBin - MIN_STANDBY_PLATES;
	if (to_dispose > 0) then
		to_dispose = math.ceil(to_dispose*.10);	-- shave off the excess 10%
		for i=1, to_dispose do
			local PLATE = w_RecycleBin[#w_RecycleBin];
			if (PLATE) then
				PLATE_Finalize(PLATE);
			end
			w_RecycleBin[#w_RecycleBin] = nil;
		end
	end
end

function ReleaseFocusedPlate()
	if (g_lastFocusedPlate) then
		PLATE_UpdateConfiguration(g_lastFocusedPlate, 0.4);
		g_lastFocusedPlate = nil;
	end
end

function HighVisPulse()
	for _,PLATE in pairs(w_PLATES) do
		if (PLATE.highVisType) then
			local range = io_HighVisRanges[PLATE.highVisType].range;
			local will_show = false;

			if (range > 0) then
				local pos = Game.GetTargetBounds(PLATE.entityId);
				if (pos) then
					will_show = (Vec3.Distance(Player.GetPosition(), pos) <= range);
				end
			end
				
			if (will_show ~= PLATE.inHighVisRange) then
				-- only update plate visibility if it comes within or goes out of range
				PLATE.inHighVisRange = will_show;
				PLATE_UpdateConfiguration(PLATE, 0.2);
			end
		end
	end
end

function SelectMediMode()
	local type = Player.GetCurrentArchtype();

	g_mediMode = MEDIMODES.NONE;

	if (type == "medic") then
		g_mediMode = MEDIMODES.MEDIC;

	elseif (type == "bunker") then
		if (io_MediModeEngineer ~= c_NoDeployables) then
			g_mediMode = MEDIMODES.ENGINEER;
		end
	end

	if (g_mediMode) then
		CYCLE_MediModePulse:Run(1);
	else
		CYCLE_MediModePulse:Stop();
		MediModePulse();
	end
end

function MediModePulse()
	local pulse_dur = 1;
	local oldPatients = {};
	local currentPatients = {};
	local maxDist2 = io_MediModeMaxRange*io_MediModeMaxRange;
	local myPos = Player.GetPosition();

	for _,PLATE in pairs(w_PLATES) do
		if (g_mediMode and not PLATE.info.hostile) then
			-- score on proximity, injury, and relation
			local score = 0;

			-- base scoring
			if (PLATE.info.squad_member or isequal(PLATE.info.ownerId, g_myId)) then
				score = 200;
			elseif (PLATE.info.type == g_mediMode.patientType and not (g_mediMode.patientType == "deployable" and io_MediModeEngineer == c_MyDeployablesOnly)) then
				score = 100;
				if (PLATE.info.isNpc) then
					if (PLATE.status.visible) then
						score = 20;
					else
						score = 0;	-- out of sight npcs are not a concern
					end
				end
			end

			if (score > 0 and PLATE.vitals.health_pct) then
				-- injury scoring
				if (PLATE.vitals.health_pct < io_MediModeHealthThreshold) then
					score = score * (1-PLATE.vitals.health_pct);
				else
					score = 0;
				end

				if (PLATE.focus) then
					-- you care about this man
					score = score * 2;
				else
					-- score by distance
					local pos = Game.GetTargetBounds(PLATE.ANCHOR:GetBoundEntity());
					if (pos) then
						local dPos = {x=pos.x-myPos.x, y=pos.y-myPos.y, z=pos.z-myPos.z};
						local dist2 = dPos.x*dPos.x + dPos.y*dPos.y + dPos.z*dPos.z;
						if (dist2 > maxDist2) then
							score = 0;
						else
							score = score * (.2 + .8/math.max(1,dist2*.1));
						end
					end
				end

				if (score > 0) then
					local patient = {score=score, PLATE=PLATE};
					currentPatients[#currentPatients + 1] = patient;
				end
			end
		end

		if (PLATE.inMediView) then
			oldPatients[PLATE.tag] = PLATE;
		end
	end

	-- pick the top N patients
	table.sort(currentPatients, SortPatients);
	local dur = 0.2;
	if (#currentPatients > 0) then
		for i = 1, math.min(g_maxPatients, #currentPatients) do
			local PLATE = currentPatients[i].PLATE;
			if (PLATE.inMediView and currentPatients[i].score > 0) then
				-- exclude from expiring list
				oldPatients[PLATE.tag] = nil;
			else
				-- add to mediview
				PLATE.inMediView = true;
				PLATE_UpdateConfiguration(PLATE, dur);
			end
			-- pulse injured portion
			PLATE.FULL_PLATE.VITALS.EMPTY:ParamTo("exposure", 1, pulse_dur/2);
			PLATE.FULL_PLATE.VITALS.EMPTY:QueueParam("exposure", -.25, pulse_dur/2);
		end
	end
	for _,PLATE in pairs(oldPatients) do
		-- remove from mediview
		PLATE.FULL_PLATE.VITALS.EMPTY:ParamTo("exposure", -0.6, pulse_dur/2);
		PLATE.inMediView = false;
		PLATE_UpdateConfiguration(PLATE, dur);
	end
end

function SortPatients(a,b)
	return (a.score > b.score);
end

-- ------------------------------------------
-- PLATE FUNCTIONS
-- ------------------------------------------
function PLATE_Construct()
	local FRAME = Component.CreateFrame("TrackingFrame");

	local PLATE = {
		FRAME = FRAME,
		ANCHOR = FRAME:GetAnchor(),
	};

	-- one time initialization
	PLATE.FRAME:SetBounds(-120, -80, 240, 160);
	PLATE.FRAME:Show(false);
	PLATE.FRAME:SetScene("world");

	PLATE.ANCHOR:SetParam("rotation",{axis={x=0,y=0,z=1}, angle=0});
	PLATE.ANCHOR:LookAt("screen");

	PLATE.FRAME:BindEvent("OnGotFocus", function()
		if (not PLATE.kill_start) then
			PLATE_OnGotFocus(PLATE);
		end
	end);

	PLATE.FRAME:BindEvent("OnLostFocus", function()
		if (not PLATE.kill_start) then
			PLATE_OnLostFocus(PLATE);
		end
	end);

	PLATE.FRAME:BindEvent("OnEdgeTrip", function(args)
		PLATE_OnEdgeTrip(PLATE, args);
	end);

	PLATE_CreateElements(PLATE);

	return PLATE;
end

function PLATE_CreateElements(PLATE)
	if (PLATE.GROUP) then
		Component.RemoveWidget(PLATE.GROUP);
		PLATE.GROUP = nil;
	end

	local GROUP = Component.CreateWidget(io_PlateStyle, PLATE.FRAME);
	PLATE.GROUP = GROUP;
	
	PLATE.MIN_PLATE = {
		GROUP = GROUP:GetChild("min_plate"),
		ART = MultiArt.Create(GROUP:GetChild("min_plate.art")),
		SHADOW = MultiArt.Create(GROUP:GetChild("min_plate.shadow")),
	};
	
	GROUP = PLATE.GROUP:GetChild("full_plate");
	PLATE.FULL_PLATE = {
		GROUP = GROUP,
		ICON = {
			GROUP = GROUP:GetChild("icon"),
			ART = MultiArt.Create(GROUP:GetChild("icon.art")),
			SHADOW = MultiArt.Create(GROUP:GetChild("icon.shadow")),
		},
		NAME = {
			GROUP = GROUP:GetChild("name"),
			TEXT = GROUP:GetChild("name.text"),
			SHADOW = GROUP:GetChild("name.shadow"),
		},
		LEVEL = {
			GROUP = GROUP:GetChild("level"),
			TEXT = GROUP:GetChild("level.text"),
			SHADOW = GROUP:GetChild("level.shadow"),
		},
		TITLE = {
			GROUP = GROUP:GetChild("title"),
			TEXT = GROUP:GetChild("title.text"),
			SHADOW = GROUP:GetChild("title.shadow"),
		},
		DEV_ICON = {
			GROUP = GROUP:GetChild("dev_icon"),
			ART = GROUP:GetChild("dev_icon.art"),
			SHADOW = GROUP:GetChild("dev_icon.shadow"),
		},
	};
	
	GROUP = PLATE.FULL_PLATE.GROUP:GetChild("vitals");
	PLATE.FULL_PLATE.VITALS = {
		GROUP = GROUP,
		FILL = GROUP:GetChild("fill"),
		SHADOW = GROUP:GetChild("shadow"),
		-- OVERFILL = GROUP:GetChild("overfill"),
		EMPTY = GROUP:GetChild("empty"),
		FLASH = GROUP:GetChild("flash"),
		DELTA = {
			GROUP = GROUP:GetChild("delta"),
			FILL = GROUP:GetChild("delta.fill"),
		},
	};
	
	-- only for iterating over to set opacity
	PLATE.SHADOWS = {
		MIN_ICON = PLATE.MIN_PLATE.SHADOW,
		NAME = PLATE.FULL_PLATE.NAME.SHADOW,
		TITLE = PLATE.FULL_PLATE.TITLE.SHADOW,
		ICON = PLATE.FULL_PLATE.ICON.SHADOW,
		DEV_ICON = PLATE.FULL_PLATE.DEV_ICON.SHADOW,
		LEVEL = PLATE.FULL_PLATE.LEVEL.SHADOW,
		VITALS = PLATE.FULL_PLATE.VITALS.SHADOW,
	};

 	PLATE.GROUP:Show(io_Enabled);
	PLATE.GROUP:SetDims("center-x:50%; bottom:50%; width:256; height:48;");
	PLATE.GROUP:SetParam("alpha", io_PlateAlpha);

	PLATE.MIN_PLATE.GROUP:SetParam("alpha", 0);
	PLATE.FULL_PLATE.GROUP:SetParam("alpha", 0);

	for _, SHADOW in pairs(PLATE.SHADOWS) do
		SHADOW:SetParam("alpha", io_ShadowAlpha);
	end

	PLATE.MIN_PLATE.SHADOW:SetParam("tint", "#000000");
	PLATE.FULL_PLATE.ICON.SHADOW:SetParam("tint", "#000000");

	PLATE.style = io_PlateStyle;
end

function PLATE_Init(PLATE, entityId)
	assert(not PLATE.tag);

	PLATE.entityId = entityId;
	PLATE.tag = tostring(entityId);

	PLATE.kill_start = nil;
	PLATE.kill_dur = nil;
	PLATE.inHighVisRange = nil;
	PLATE.inMediView = false;
	PLATE.focus = false;
	
	PLATE.FRAME:Show(false);

	if (PLATE.style ~= io_PlateStyle) then
		PLATE_CreateElements(PLATE);
	else
		-- reset visibility
		PLATE.GROUP:Show(io_Enabled);
		PLATE.GROUP:SetParam("alpha", io_PlateAlpha);

		PLATE.MIN_PLATE.GROUP:SetParam("alpha", 0);
		PLATE.FULL_PLATE.GROUP:SetParam("alpha", 0);

		for _, SHADOW in pairs(PLATE.SHADOWS) do
			SHADOW:SetParam("alpha", io_ShadowAlpha);
		end
	end

	if (w_PLATES[PLATE.tag]) then
		local PRE_PLATE = w_PLATES[PLATE.tag];
		error(PRE_PLATE.info.name.." ("..tostring(entityId)..") is already registered!");
	end
	w_PLATES[PLATE.tag] = PLATE;

	-- initialize frame
	local bindSuccess = PLATE.ANCHOR:BindToEntity(entityId, "HP_SinCard", "FX_Head", false, true);
	if (bindSuccess) then
		PLATE.ANCHOR:SetParam("translation", {x=0, y=0, z=0.2});
		PLATE.ANCHOR:SetParam("entity_bounds_offset", {x=0, y=0, z=0});
	else
		PLATE.ANCHOR:SetParam("translation", {x=0, y=0, z=0});
		PLATE.ANCHOR:SetParam("entity_bounds_offset", {x=0, y=0, z=1});
	end

	local bounds = Game.GetTargetBounds(entityId, true);
	if (bounds) then
		PLATE.prominence = (bounds.width+bounds.height+bounds.length)/6;
	else
		PLATE.prominence = 1;
	end

	PLATE.FRAME:SetFocalMode(true);
	PLATE.FRAME:SetParam("alpha", 1);
	PLATE.FRAME:SetParam("prominence", PLATE.prominence);

	local info = Game.GetTargetInfo(PLATE.entityId) or {};
	local rules = EntityRules.GetRules(info);

	-- create and bind map marker
	if (not PLATE.MAPMARKER and (rules.worldmap or rules.radar)) then
		PLATE.MAPMARKER = MapMarker.Create();
	end

	if (PLATE.MAPMARKER) then
		PLATE.MAPMARKER:BindToEntity(entityId);
		PLATE.MAPMARKER:GetIcon():SetParam("alpha", 1);

		PLATE.MAPMARKER:AddHandler("OnGotFocus", function()
			g_focused_MARKER = PLATE.MAPMARKER;
			MAP_INFO_GROUP:Show(true);
			if (PLATE.FULL_PLATE.VITALS.GROUP:IsVisible()) then
				Component.FosterWidget(PLATE.FULL_PLATE.VITALS.GROUP, MAP_INFO_VITALS);
				--MAP_INFO_VITALS:SetTarget(PLATE.FULL_PLATE.VITALS.GROUP);
			else
				MAP_INFO_VITALS:SetTarget(nil);
			end
			PLATE.FULL_PLATE.VITALS.GROUP:SetParam("alpha", 1);
			Component.FosterWidget(MAP_INFO_GROUP, PLATE.MAPMARKER:GetBody());
			MapInfo_Update(PLATE)
		end);

		PLATE.MAPMARKER:AddHandler("OnLostFocus", function()
			PLATE.FULL_PLATE.VITALS.GROUP:SetParam("alpha", 0);
			Component.FosterWidget(PLATE.FULL_PLATE.VITALS.GROUP, nil);
			if (g_focused_MARKER == PLATE.MAPMARKER) then
				MAP_INFO_GROUP:Show(false);
				g_focused_MARKER = nil;
			end
		end);
	end

	-- initialize cached data
	PLATE.info = {};
	PLATE.rules = nil;
	PLATE.status = {};
	PLATE.vitals = {};
	PLATE.icon = nil;
	PLATE.priority = PRIORITY_NONE;

	return PLATE;
end

local function ElementColor(element_name, rules)
	local setting = io_ColorSettings[element_name]
	if setting == "relationship" then
		return io_RelationshipColors[rules.relationship]
	elseif setting == "stage" then
		return io_StageColors[rules.stage] or io_RelationshipColors[rules.relationship]
	end 
end
function PLATE_UpdateInfo(PLATE)
	local info = Game.GetTargetInfo(PLATE.entityId) or {};
	local rules = EntityRules.GetRules(info);
	
	PLATE.FULL_PLATE.NAME.TEXT:SetText(rules.name);
	PLATE.FULL_PLATE.NAME.SHADOW:SetText(rules.name);
	
	if (rules.title) then
		PLATE.FULL_PLATE.TITLE.TEXT:SetText(rules.title);
		PLATE.FULL_PLATE.TITLE.SHADOW:SetText(rules.title);
		PLATE.FULL_PLATE.TITLE.GROUP:Show(true);
	else
		PLATE.FULL_PLATE.TITLE.GROUP:Show(false);
	end

	if (info.level and info.level > 0) then
		PLATE.FULL_PLATE.LEVEL.TEXT:SetText(info.effective_level or info.level);
		PLATE.FULL_PLATE.LEVEL.SHADOW:SetText(info.effective_level or info.level);
		PLATE.FULL_PLATE.LEVEL.GROUP:Show(true);
	else
		PLATE.FULL_PLATE.LEVEL.GROUP:Show(false);
	end

	if (rules.use_icon) then
		PLATE.icon = {use_icon=rules.use_icon, texture=rules.texture, region=rules.region, icon_url=rules.icon_url};
		SetIconVisuals(PLATE.MIN_PLATE.ART, rules);
		SetIconVisuals(PLATE.MIN_PLATE.SHADOW, rules);
		SetIconVisuals(PLATE.FULL_PLATE.ICON.ART, rules);
		SetIconVisuals(PLATE.FULL_PLATE.ICON.SHADOW, rules);
		PLATE.MIN_PLATE.GROUP:Show(true);
		PLATE.FULL_PLATE.ICON.GROUP:Show(true);
	else
		PLATE.icon = nil;
		PLATE.MIN_PLATE.GROUP:Show(false);
		PLATE.FULL_PLATE.ICON.GROUP:Show(false);
	end

	if (info.isDev) then
		PLATE.FULL_PLATE.DEV_ICON.GROUP:Show(true);
	else
		PLATE.FULL_PLATE.DEV_ICON.GROUP:Show(false);
	end

	local vitals = Game.GetTargetVitals(PLATE.entityId) or {};
	if (vitals.MaxHealth ~= nil and vitals.MaxHealth ~= 0) then
		PLATE.FULL_PLATE.VITALS.GROUP:Show(true);
	else
		PLATE.FULL_PLATE.VITALS.GROUP:Show(false);
	end

	-- marker set up
	if (PLATE.MAPMARKER) then
		PLATE.MAPMARKER:SetTitle(rules.name);
		PLATE.MAPMARKER:SetSubtitle(rules.title);

		local ICON = PLATE.MAPMARKER:GetIcon();
		if (not PLATE.MAPMARKER.texture_override) then
			SetIconVisuals(ICON, rules)
		end
		local scale = math.ceil(65 * rules.marker_scale);
		ICON:SetDims("width:" .. scale .. "%; height:" .. scale .. "%");

		PLATE.MAPMARKER:ShowOnWorldMap(rules.worldmap, rules.min_zoom, rules.max_zoom);
		PLATE.MAPMARKER:ShowOnRadar(rules.radar);
		PLATE.MAPMARKER:SetRadarEdgeMode(rules.edge_mode);
	end

	-- priority settings
	if (info.squad_member) then
		PLATE.priority = PRIORITY_HIGH;
	elseif (info.hostile or (info.type == "character" and not info.isNpc)) then
		PLATE.priority = PRIORITY_MEDIUM;
	else
		PLATE.priority = PRIORITY_LOW;
	end

	-- increased visibility settings
	if (rules.region == "business") then
		PLATE.highVisType = "VENDORS";
	elseif (rules.region == "glider") then
		PLATE.highVisType = "GLIDER_PADS";
	elseif (rules.region == "battleframe_station") then
		PLATE.highVisType = "BATTLEFRAME_STATIONS";
	elseif (ARES_ITEMS[rules.name]) then
		PLATE.highVisType = "ARES_ITEMS";
	else
		PLATE.highVisType = nil;
	end

	PLATE.info = info;
	PLATE.rules = rules;
	
	PLATE_UpdateLayout(PLATE);
	PLATE_UpdateVisibility(PLATE);
end

function PLATE_UpdateLayout(PLATE)
	-- updates layout/colors for visible elements
	local rules = PLATE.rules;
	if (not rules) then
		return;
	end
	
	local has_title = PLATE.FULL_PLATE.TITLE.GROUP:IsVisible();
	local has_dev_icon = PLATE.FULL_PLATE.DEV_ICON.GROUP:IsVisible();
	local has_icon = PLATE.FULL_PLATE.ICON.GROUP:IsVisible();
	local has_level = PLATE.FULL_PLATE.LEVEL.GROUP:IsVisible();
	local has_vitals = PLATE.FULL_PLATE.VITALS.GROUP:IsVisible();

	if (PLATE.style == c_Modern) then
		local centered = not (has_vitals or has_dev_icon) and not (has_icon and has_title);

		if (centered) then
			PLATE.FULL_PLATE.NAME.GROUP:SetDims("left:" .. 128 - PLATE.FULL_PLATE.NAME.TEXT:GetTextDims().width/2 .. "; width:_;");

			if (has_title) then
				PLATE.FULL_PLATE.TITLE.GROUP:SetDims("left:" .. 128 - PLATE.FULL_PLATE.TITLE.TEXT:GetTextDims().width/2 .. "; width_;");
			elseif (has_icon) then
				PLATE.FULL_PLATE.ICON.GROUP:SetDims("right:" .. PLATE.FULL_PLATE.NAME.GROUP:GetDims().left.offset - 2 .. "; width:_;");
			end

			if (has_level) then
				PLATE.FULL_PLATE.LEVEL.GROUP:SetDims("right:" .. ((has_icon and PLATE.FULL_PLATE.ICON.GROUP:GetDims().left.offset)
					or PLATE.FULL_PLATE.NAME.GROUP:GetDims().left.offset) - 3 .. "; width:_;");
			end

		else
			PLATE.FULL_PLATE.NAME.GROUP:SetDims("left:" .. ((has_dev_icon and PLATE.FULL_PLATE.DEV_ICON.GROUP:GetDims().right.offset) or 87) .. "; width:_;");

			if (has_title) then
				PLATE.FULL_PLATE.TITLE.GROUP:SetDims("left:87; width:_;");
			end

			if (has_icon) then
				PLATE.FULL_PLATE.ICON.GROUP:SetDims("right:85; width:_;");
			end

			if (has_level) then
				PLATE.FULL_PLATE.LEVEL.GROUP:SetDims("right:" .. ((has_icon and PLATE.FULL_PLATE.ICON.GROUP:GetDims().left.offset) or 87) - 3 .. "; width:_;");
			end
		end

	elseif (PLATE.style == c_Beta) then
		local offset = 128 - (PLATE.FULL_PLATE.NAME.TEXT:GetTextDims().width
			- ((has_dev_icon and PLATE.FULL_PLATE.DEV_ICON.GROUP:GetBounds().width) or 0)) / 2;

		PLATE.FULL_PLATE.NAME.GROUP:SetDims("left:" .. offset	.. "; width:_;");

		if (has_dev_icon) then
			PLATE.FULL_PLATE.DEV_ICON.GROUP:SetDims("right:" .. offset .. "; width:_;");
			offset = PLATE.FULL_PLATE.DEV_ICON.GROUP:GetDims().left.offset;
		end

		if (has_icon) then
			PLATE.FULL_PLATE.ICON.GROUP:SetDims("right:" .. offset - 2 .. "; width:_;");
			offset = PLATE.FULL_PLATE.ICON.GROUP:GetDims().left.offset;
		end

		if (has_level) then
			PLATE.FULL_PLATE.LEVEL.GROUP:SetDims("right:" .. offset - 3 .. "; width:_;");
		end
	end

	-- colors
	local name_color = ElementColor("name", rules)
	PLATE.FULL_PLATE.NAME.TEXT:SetTextColor(name_color)

	if (has_title) then
		PLATE.FULL_PLATE.TITLE.TEXT:SetTextColor(ElementColor("title", rules));
	end

	if (has_level) then
		PLATE.FULL_PLATE.LEVEL.TEXT:SetTextColor(ElementColor("level", rules));
	end

	if (has_vitals) then
		PLATE.FULL_PLATE.VITALS.FILL:SetParam("tint", ElementColor("health_bar", rules));
	end

	if (has_icon or PLATE.MAPMARKER) then
		local icon_color = ElementColor("icon", rules);

		if (has_icon) then
			PLATE.MIN_PLATE.ART:SetParam("tint", icon_color);
			PLATE.FULL_PLATE.ICON.ART:SetParam("tint", icon_color);
		end

		if (PLATE.MAPMARKER) then
			PLATE.MAPMARKER:GetIcon():SetParam("tint", icon_color);
		end
	end
end

function PLATE_UpdateVisibility(PLATE)
	local info = PLATE.info or {};
	local suppression = d_suppressedEntities[PLATE.tag];	-- tag = tostring(entityId)
	local will_show = (not info.hidden) and (suppression ~= SUPPRESS_ALL and suppression ~= SUPPRESS_HUD);

	if (not will_show) then
		-- special case: hide *GROUP* instead if this is interactable, since we need the FRAME to be visible and catch focus
		local interactInfo = Player.GetInteracteeInfo(PLATE.entityId);
		if (interactInfo and interactInfo.interactType) then
			will_show = true;
		end
	end
	
	PLATE.FRAME:Show(will_show);
end

function PLATE_UpdateVitals(PLATE, dur)
	local vitals = Game.GetTargetVitals(PLATE.entityId) or {};
	local has_vitals = (vitals.MaxHealth ~= nil and vitals.MaxHealth ~= 0);

	if (PLATE.info and (has_vitals ~= PLATE.FULL_PLATE.VITALS.GROUP:IsVisible())) then
		PLATE.FULL_PLATE.VITALS.GROUP:Show(has_vitals);
		PLATE_UpdateLayout(PLATE);
		PLATE_UpdateConfiguration(PLATE, 0.1);
	end

	if (PLATE.vitals.health_pct ~= vitals.health_pct) then
		if (vitals.health_pct) then
			local pct = math.ceil(vitals.health_pct * 100);
			local fill_pct = math.min(100, pct);
			-- local overfill_pct = math.max(0, pct - 100);

			PLATE.FULL_PLATE.VITALS.FILL:MaskMoveTo("left:_; width:" .. fill_pct .. "%", dur, 0, "ease-in");
			PLATE.FULL_PLATE.VITALS.SHADOW:MaskMoveTo("left:_; width:" .. fill_pct .. "%", dur, 0, "ease-in");
			PLATE.FULL_PLATE.VITALS.EMPTY:MaskMoveTo("right:_; width:" .. (100 - fill_pct) .. "%-1", dur, 0, "ease-in");
			-- PLATE.FULL_PLATE.VITALS.OVERFILL:MaskMoveTo("left:_; width:" .. overfill_pct .. "%", dur, 0, "ease-in");

			if (pct <= 100) then
				Component.FosterWidget(PLATE.FULL_PLATE.VITALS.DELTA.GROUP, PLATE.FULL_PLATE.VITALS.FILL);
			else
				-- Component.FosterWidget(PLATE.FULL_PLATE.VITALS.DELTA.GROUP, PLATE.FULL_PLATE.VITALS.OVERFILL);
			end

			if (pct >= 100) then
				if (io_HideFullHealthbars) then
					PLATE.FULL_PLATE.VITALS.GROUP:ParamTo("alpha", 0, dur*2);
				end
			else
				if (io_HideFullHealthbars) then
					PLATE.FULL_PLATE.VITALS.GROUP:ParamTo("alpha", 1, dur);
				end
			end

		end
	end
	PLATE.vitals = vitals;
end

function PLATE_AnimateHit(PLATE, damage, dur)
	if (PLATE.vitals.health_pct and damage ~= 0) then
		local bar_pct = math.max(PLATE.vitals.health_pct, .01);
		local delta_pct = 1;
		if (bar_pct > 1) then
			bar_pct = bar_pct%1;
		end
		if (bar_pct > 0 and PLATE.vitals.MaxHealth > 0) then
			delta_pct = math.ceil(math.abs(100*damage/PLATE.vitals.MaxHealth/bar_pct));
		end
		if (damage > 0) then
			PLATE.FULL_PLATE.VITALS.DELTA.GROUP:SetDims("right:100%; width:"..math.min(100, delta_pct).."%+1");
			PLATE.FULL_PLATE.VITALS.DELTA.GROUP:MoveTo("right:_; width:0", dur, 0, "ease-in");
			PLATE.FULL_PLATE.VITALS.DELTA.FILL:SetParam("tint", COLOR_DAMAGE);
			PLATE.FULL_PLATE.VITALS.DELTA.FILL:SetParam("glow", COLOR_DAMAGE);
		else
			PLATE.FULL_PLATE.VITALS.DELTA.GROUP:SetDims("left:100%; width:"..math.min(100*(1-bar_pct)/bar_pct, delta_pct).."%+1");
			PLATE.FULL_PLATE.VITALS.DELTA.GROUP:MoveTo("left:_; width:0", dur, 0, "ease-in");
			PLATE.FULL_PLATE.VITALS.DELTA.FILL:SetParam("tint", COLOR_HEALING);
			PLATE.FULL_PLATE.VITALS.DELTA.FILL:SetParam("glow", COLOR_HEALING);
		end
		PLATE.FULL_PLATE.VITALS.DELTA.GROUP:SetParam("alpha", 1);
		PLATE.FULL_PLATE.VITALS.DELTA.GROUP:ParamTo("alpha", 0, dur, 0, "ease-in");
	end
end

function PLATE_UpdateStatus(PLATE, dur)
	local status = Game.GetTargetStatus(PLATE.entityId);
	if status then
		PLATE.status = status;

		if PLATE.MAPMARKER then
			local ICON = PLATE.MAPMARKER:GetIcon();
			if not isequal(PLATE.info.type, "vehicle") and (status.state == "incapacitated") then
				PLATE.MAPMARKER.texture_override = true;
				ICON:SetTexture("MapMarkers", "skull");
				ICON:ParamTo("alpha", 1, dur);
			elseif not isequal(PLATE.info.type, "vehicle") and (status.state == "dead") then
				PLATE.MAPMARKER.texture_override = true;
				ICON:SetTexture("MapMarkers", "skull");
				ICON:ParamTo("alpha", 0.4, dur);
			else
				PLATE.MAPMARKER.texture_override = false;
				if (PLATE.icon) then
					SetIconVisuals(ICON, PLATE.icon)
				end
				ICON:ParamTo("alpha", 1, dur);
			end
		end

		if (status.visible) then
			PLATE.FRAME:SetParam("prominence", PLATE.prominence);
		else
			PLATE.FRAME:SetParam("prominence", 0);
		end
	else
		warn("Game.GetTargetStatus returned nil")
	end
end

function PLATE_UpdateConfiguration(PLATE, dur)
	-- shuffles and shows/hides elements
	local is_hostile_npc = (PLATE.info.hostile and PLATE.info.isNpc);
	local is_other_player = (PLATE.info.type == "character" and not PLATE.info.isNpc);
	local is_dead = (PLATE.status.state == "dead");
	local has_vitals = (PLATE.vitals.MaxHealth ~= nil and PLATE.vitals.MaxHealth ~= 0);

	local interested = ((PLATE.focus and PLATE.status.visible) or PLATE.inMediView
		or (g_sinView and PLATE.icon) or (io_HighVisiblity and PLATE.inHighVisRange));
	local priority = PLATE.priority;

	local show_top_icon = (PLATE.icon and PLATE.status.inSin and not is_dead);
	local show_header = (PLATE.info.name ~= nil and not is_dead and g_Loaded);
	local show_title = ((g_sinView and io_ShowTitles == c_SinViewOnly) or io_ShowTitles == c_Always);
	local show_level = (((g_sinView and io_ShowLevels == c_SinViewOnly) or io_ShowLevels == c_Always)
		and not (io_HideLevelsForNPCs and not (is_hostile_npc or is_other_player)));
	local show_vitals = ((PLATE.vitals.health_pct ~= nil)
		and not (io_HideFullHealthbars and PLATE.vitals.health_pct >= 1));

	if (not g_ShowHud) then
		interested = false;
		show_top_icon = false;
		show_header = false;
		priority = PRIORITY_NONE;
	end

	if (interested) then
		priority = math.max(priority, PRIORITY_MEDIUM);
	else
		show_header = false;
	end

	if (g_spectating and priority >= PRIORITY_MEDIUM) then
		show_header = true;
		show_vitals = has_vitals;
	end

	if (show_header) then
		show_top_icon = false;
	end

	local priority_setting = PRIORITY_SETTINGS[priority];
	local dock_to_edge = (priority_setting.docks_to_edge or PLATE.inMediView);

	if (not dock_to_edge and PLATE.minimized) then
		PLATE.minimized = false;
	elseif (dock_to_edge and not PLATE.minimized and PLATE.docked) then
		PLATE.minimized = true;
	end

	if (PLATE.minimized and io_MinimizeDockedPlates) then
		show_level = false;
		show_title = false;
	end

	if (show_top_icon) then
		PLATE.MIN_PLATE.GROUP:ParamTo("alpha", 1, dur);
	else
		PLATE.MIN_PLATE.GROUP:ParamTo("alpha", 0, dur);
	end

	if (show_header) then
		PLATE.FULL_PLATE.GROUP:ParamTo("alpha", 1, dur);
	else
		PLATE.FULL_PLATE.GROUP:ParamTo("alpha", 0, dur);
	end

	if (show_title) then
		PLATE.FULL_PLATE.TITLE.GROUP:ParamTo("alpha", 1, dur);
	else
		PLATE.FULL_PLATE.TITLE.GROUP:FinishParam("alpha");
		PLATE.FULL_PLATE.TITLE.GROUP:ParamTo("alpha", 0, dur);
	end

	if (show_level) then
		PLATE.FULL_PLATE.LEVEL.GROUP:ParamTo("alpha", 1, dur);
	else
		PLATE.FULL_PLATE.LEVEL.GROUP:FinishParam("alpha");
		PLATE.FULL_PLATE.LEVEL.GROUP:ParamTo("alpha", 0, dur);
	end

	if (show_vitals) then
		PLATE.FULL_PLATE.VITALS.GROUP:ParamTo("alpha", 1, dur);
	else
		PLATE.FULL_PLATE.VITALS.GROUP:ParamTo("alpha", 0, dur);
	end

	PLATE.ANCHOR:LookAt("screen", dock_to_edge);
	PLATE.FRAME:ParamTo("cullalpha", priority_setting.cull_alpha, dur);
end

function PLATE_RecycleOut(PLATE)
	-- dump it here
	PLATE.ANCHOR:BindToEntity(nil);
	PLATE.FRAME:Show(false);

	w_PLATES[PLATE.tag] = nil;
	w_ToRecycle[PLATE.tag] = nil;
	PLATE.tag = nil;
	PLATE.entityId = nil;

	if (PLATE.MAPMARKER) then
		PLATE.MAPMARKER:ShowOnWorldMap(false);
		PLATE.MAPMARKER:ShowOnRadar(false);
		PLATE.MAPMARKER:SetRadarEdgeMode(MapMarker.EDGE_NONE);
		PLATE.MAPMARKER.texture_override = false;
	end

	w_RecycleBin[#w_RecycleBin+1] = PLATE;
	if (g_lastFocusedPlate == PLATE) then
		g_lastFocusedPlate = nil;
	end
end

function PrepareCleanPLATE(entityId)
	local n = #w_RecycleBin;
	local PLATE = w_RecycleBin[n];
	if (PLATE) then
		w_RecycleBin[n] = nil;
	else
		-- create one
		PLATE = PLATE_Construct();
	end
	-- initialize
	PLATE_Init(PLATE, entityId);

	return PLATE;
end

function PLATE_Finalize(PLATE)
	if (PLATE.GROUP) then
		Component.RemoveWidget(PLATE.GROUP);
		PLATE.GROUP = nil;
	end
	if (PLATE.MAPMARKER) then
		PLATE.MAPMARKER:Destroy();
		PLATE.MAPMARKER = nil;
	end
	if (PLATE.FRAME) then
		Component.RemoveFrame(PLATE.FRAME);
		PLATE.FRAME = nil;
	end
end

function PLATE_SlowKill(PLATE, death_dur)
	if (PLATE == nil) then
		return;
	end

	PLATE.FRAME:ParamTo("alpha", 0, death_dur);
	PLATE.FRAME:SetFocalMode(false);
	PLATE.kill_start = System.GetClientTime();
	PLATE.kill_dur = death_dur;

	if PLATE.MAPMARKER then
		PLATE.MAPMARKER:GetIcon():ParamTo("alpha", 0, death_dur);
	end

	-- move into the ToRecycle pile
	w_PLATES[PLATE.tag] = nil;
	assert(not w_ToRecycle[PLATE.tag], "there can only be one");
	w_ToRecycle[PLATE.tag] = PLATE;

	if (not CB2_RecyclePlates:Pending()) then
		CB2_RecyclePlates:Schedule(PLATE.kill_dur);
	end
end

function MapInfo_Create()
	w_MAP_INFO = {
		ICON = MultiArt.Create(MAP_INFO_GROUP:GetChild("detail.icon_group")),
		NAME = MAP_INFO_GROUP:GetChild("readouts.name"),
		TITLE = MAP_INFO_GROUP:GetChild("readouts.title"),
	}
end

function MapInfo_Update(PLATE)
	local info = Game.GetTargetInfo(PLATE.entityId) or {};
	local rules = EntityRules.GetRules(info);

	w_MAP_INFO.rules = rules;
	w_MAP_INFO.NAME:SetText(rules.name);

	if (rules.title) then
		w_MAP_INFO.TITLE:SetText(rules.title);
		w_MAP_INFO.TITLE:Show(true);
	else
		w_MAP_INFO.TITLE:Show(false);
	end

	w_MAP_INFO.ICON:SetParam("tint", (io_ColorSettings.icon == "relationship" and io_RelationshipColors[rules.relationship])
		or (io_ColorSettings.icon == "stage" and (io_StageColors[rules.stage] or io_RelationshipColors[rules.relationship])));

	w_MAP_INFO.TITLE:SetTextColor((io_ColorSettings.title == "relationship" and io_RelationshipColors[rules.relationship])
		or (io_ColorSettings.title == "stage" and (io_StageColors[rules.stage] or io_RelationshipColors[rules.relationship])));

	w_MAP_INFO.NAME:SetTextColor((io_ColorSettings.name == "relationship" and io_RelationshipColors[rules.relationship])
		or (io_ColorSettings.name == "stage" and (io_StageColors[rules.stage] or io_RelationshipColors[rules.relationship])));

	SetIconVisuals(w_MAP_INFO.ICON, rules);
end

function SetIconVisuals(ICON, rules)
	if type(rules) == "table" then
		if rules.icon_url and not io_UseArchetypeIcon then
			ICON:SetUrl(rules.icon_url);
		elseif rules.texture then
			ICON:SetTexture(rules.texture, rules.region);
		end
	end
end