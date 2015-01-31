
-- ------------------------------------------
-- Entity Plates
--   by: John Su
-- ------------------------------------------

require "unicode";
require "math";
require "table";
require "./EntityRules";
require "lib/lib_Callback2";
require "lib/lib_MapMarker";
require "lib/lib_Liaison";
require "lib/lib_math";
require "lib/lib_MultiArt"
require "lib/lib_HudManager"

-- ------------------------------------------
-- CONSTANTS
-- ------------------------------------------
local MAP_INFO_GROUP = Component.GetWidget("map_info");
local MAP_INFO_VITALS = Component.GetWidget("shadow_vitals");

local w_MAP_INFO

local PRIORITY_NONE = 0;	-- I don't care
local PRIORITY_LOW = 1;		-- deployables, npc's; things that are not urgent
local PRIORITY_MEDIUM = 2;	-- enemies, allies; combat significant
local PRIORITY_HIGH = 3;	-- squadmates

local SPECTATOR_TEAM = "1";

-- for use in entity suppression
local SUPPRESS_HUD = "hud";	-- don't show HUD plate
local SUPPRESS_MAP = "map";	-- don't show radar/map entries
local SUPPRESS_ALL = "all";	-- don't show ANYTHING

local PRIORITY_SETTINGS = {
[PRIORITY_NONE]		= {cull_alpha=0},
[PRIORITY_LOW]		= {cull_alpha=0},
[PRIORITY_MEDIUM]	= {cull_alpha=0.8},
[PRIORITY_HIGH]		= {cull_alpha=0.8, always_visible=true, docks_to_edge=true},
}

local IGNORE_TYPES = {
	["loot"]		= true,
	["sin_object"]	= true,
	["Globe"]		= true,
}

local MEDIMODE_MAX_RANGE = 80;	-- in meters

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
local g_lastSinActionTime = nil;	-- last time SIN view was activated
local g_lastFocusedPlate = nil;
local g_focused_MARKER = nil;
local g_medimode = false;	-- medic on the prowl, looking for injured allies
local g_maxPatients = 20;	-- max patients to show
local CYCLE_DisposePlates;
local CB2_RecyclePlates = Callback2.Create();
local CB2_MedimodePulse = Callback2.Create();
local CB2_ReleaseFocusedPlate = Callback2.Create();

local g_is_challenge_ready = false;


-- ------------------------------------------
-- INTERFACE OPTIONS
-- ------------------------------------------
require "lib/lib_InterfaceOptions"
local io_Enabled = true
local io_Alpha = 1
local io_UseArchTypeIcon = false




InterfaceOptions.SaveVersion(1.4)
InterfaceOptions.AddCheckBox({id="ENABLED", label_key="ENTITY_PLATES_ENABLED", default=io_Enabled})
InterfaceOptions.AddSlider({id="PLATE_ALPHA", label_key="ENTITY_PLATES_ALPHA", default=io_Alpha, min=0, max=1, inc=0.01, format="%0.0f", multi=100, suffix="%"})
InterfaceOptions.AddCheckBox({id="ARCHTYPE_ICON", label_key="USE_ARCHTYPE_ICON", default=io_UseArchTypeIcon})








function OnOptionChange(id, val)
	if id == "ENABLED" then
		io_Enabled = val
		for _, PLATE in pairs(w_PLATES) do
			PLATE.GROUP:Show(io_Enabled)
		end
		SetOptionsAvailability()
	elseif id == "PLATE_ALPHA" then
		io_Alpha = val
		for _, PLATE in pairs(w_PLATES) do
			PLATE.GROUP:SetParam("alpha", io_Alpha)
		end
	elseif id == "ARCHTYPE_ICON" then
		io_UseArchTypeIcon = val
		for _, PLATE in pairs(w_PLATES) do
			if PLATE.icon then
				if PLATE.icon.use_icon then
					SetIconVisuals(PLATE.MIN_PLATE.ICON, PLATE.icon)
					if not PLATE.deferred then
						SetIconVisuals(PLATE.FULL_PLATE.ICON, PLATE.icon)
					end
				end
				if PLATE.MAPMARKER and not PLATE.MAPMARKER.texture_override then
					SetIconVisuals(PLATE.MAPMARKER:GetIcon(), PLATE.icon)
				end
			end
			if w_MAP_INFO then
				SetIconVisuals(w_MAP_INFO.ICON, w_MAP_INFO.rules)
			end
		end











	end
end

function SetOptionsAvailability()
	local disabled = not io_Enabled
	InterfaceOptions.DisableOption("PLATE_ALPHA", disabled)
	InterfaceOptions.DisableOption("ARCHTYPE_ICON", disabled)
	



end

-- ------------------------------------------
-- EVENT FUNCTIONS
-- ------------------------------------------
function OnComponentLoad()
	InterfaceOptions.SetCallbackFunc(OnOptionChange, Component.LookupText("ENTITY_PLATES"))
	g_lastSinActionTime = System.GetClientTime();
	g_myTeamId = SPECTATOR_TEAM;
	
	MapInfo_Create()
	
	CB2_RecyclePlates:Bind(RecyclePlates);
	CB2_MedimodePulse:Bind(MedimodePulse);
	CB2_ReleaseFocusedPlate:Bind(ReleaseFocusedPlate);
	
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
	
	g_PlayerName = Player.GetInfo().name;
end

function OnHudShow(show, dur)
	g_ShowHud = show;
	for tag,PLATE in pairs(w_PLATES) do
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
	for tag,PLATE in pairs(w_PLATES) do 
		PLATE_UpdateInfo(PLATE);
	end
end

function OnLevelChanged()
	for tag,PLATE in pairs(w_PLATES) do 
		PLATE_UpdateInfo(PLATE);
	end
end

function OnBattleframeChanged()
	local type = Player.GetCurrentArchtype();
	local medimode = MEDIMODES.NONE;
	if (type == "medic") then
		medimode = MEDIMODES.MEDIC;
	elseif (type == "bunker") then
		medimode = MEDIMODES.ENGINEER;
	end
		
	if (medimode ~= g_medimode) then
		g_medimode = medimode;
		if (CB2_MedimodePulse:Pending()) then
			CB2_MedimodePulse:Execute();
		else
			MedimodePulse();
		end		
	end
	
	OnLevelChanged();
end

function OnHideEntity(args)
	local entityId = tostring(args.entityId);
	local hide = args.hide;	-- "all"/true, "map", "hud", or false
	local PLATE = GetPlateFromArgs(args);
	if (hide) then
		d_suppressedEntities[entityId] = hide;
		if (PLATE) then
			if (hide == SUPPRESS_ALL or hide == true) then
				OnEntityLost({entityId=entityId, timeout=1});
			else
				PLATE_UpdateVisibility(PLATE);
			end
		end
	else
		d_suppressedEntities[entityId] = nil;
		if (PLATE) then
			PLATE_UpdateVisibility(PLATE);
		else
			local info = Game.GetTargetInfo(entityId);
			if (info) then
				OnEntityAvailable({entityId=entityId, type=info.type});
			end
		end
	end
end

function OnEntityAvailable(args)
	-- args = {entityId, type}
	if ( (g_spectating_follow and isequal(args.entityId, g_myId)) or IGNORE_TYPES[args.type]
		or d_suppressedEntities[tostring(args.entityId)]) then
		-- ignore self, IGNORE_TYPES, and entities suppressed by other UI
		return false;
	end
	
	-- put the dying predecessor into the recycle bin for immediate use, if it exists
	local tag = tostring(args.entityId);
	local PLATE = w_ToRecycle[tag];
	if (PLATE) then
		PLATE_RecycleOut(PLATE);
	end
	
	PLATE = GetPlateFromArgs({entityId=args.entityId});
	if( not PLATE ) then
		PLATE = PrepareCleanPLATE(args.entityId);
	end	
	
	PLATE_UpdateInfo(PLATE);
	PLATE_UpdateVitals(PLATE, 0);
	PLATE_UpdateStatus(PLATE, 0);
	PLATE_UpdateConfiguration(PLATE, 0.1);
	PLATE_UpdateMediMode(PLATE);	
end

function OnEntityLost(args)
	-- args = {entityId[, timeout]}	
	local PLATE = GetPlateFromArgs(args);
	if (not PLATE) then
		return;	-- none of our concern
	end
	
	if (args.timeout) then
		if (not PLATE) then
			error("Could not find PLATE for "..tostring(args.entityId));
		end
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

function OnSimulatedHit( args )
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
		System.PlaySound("Play_UI_SINView_Mode")
	else
		System.PlaySound("Stop_UI_SINView_Mode")
	end
	g_lastSinActionTime = System.GetClientTime();
	for tag,PLATE in pairs(w_PLATES) do
		-- only reveal entities with enough importance to have an icon
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
		if (g_lastFocusedPlate and g_lastFocusedPlate.focus) then
			-- GotFocus must have fired before LostFocus; execute release immediately
			g_lastFocusedPlate.focus = false;
			CB2_ReleaseFocusedPlate:Cancel();
			CB2_ReleaseFocusedPlate:Schedule(0);
		elseif (CB2_ReleaseFocusedPlate:Pending() and g_lastFocusedPlate) then
			-- hurry up and disappear
			CB2_ReleaseFocusedPlate:Execute();
		end
		g_lastFocusedPlate = PLATE;
	end
end

function PLATE_OnLostFocus(PLATE)
	PLATE.focus = false;
	-- slow fade
	if (CB2_ReleaseFocusedPlate:Pending()) then
		CB2_ReleaseFocusedPlate:Reschedule(RELEASE_PLATE_FOCUS_DELAY);
	else
		CB2_ReleaseFocusedPlate:Schedule(RELEASE_PLATE_FOCUS_DELAY);
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

function MedimodePulse()
	local pulse_dur = 1;
	local oldPatients = {};
	local currentPatients = {};
	
	local maxDist2 = MEDIMODE_MAX_RANGE*MEDIMODE_MAX_RANGE;
	local myPos = Player.GetPosition();
	for tag,PLATE in pairs(w_PLATES) do
		if (g_medimode and not PLATE.info.hostile) then
			-- score on proximity, injury, and relation
			local score = 0;
			
			-- base scoring
			if (PLATE.info.squad_member or isequal(PLATE.info.ownerId, g_myId)) then
				score = 200;
			elseif (PLATE.info.type == g_medimode.patientType) then
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
				score = score * (1-PLATE.vitals.health_pct);
				
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
					table.insert(currentPatients, patient);
				end
			end
		end
		
		if (PLATE.inMediview) then
			oldPatients[PLATE.tag] = PLATE;
		end
	end
	
	-- pick the top N patients
	table.sort(currentPatients, SortPatients);
	local dur = 0.2;
	if (#currentPatients > 0) then
		for i = 1, math.min(g_maxPatients, #currentPatients) do
			local PLATE = currentPatients[i].PLATE;
			if (PLATE.inMediview) then
				-- exclude from expiring list
				oldPatients[PLATE.tag] = nil;
			else
				-- add to mediview
				PLATE.inMediview = true;
				PLATE_UpdateMediMode(PLATE);
				PLATE_UpdateConfiguration(PLATE, dur);
			end
			-- pulse injured portion
			if PLATE.deferred then
				PLATE_DeferredCreation(PLATE)
			end
			PLATE.FULL_PLATE.VITALS.EMPTY:ParamTo("exposure", 1, pulse_dur/2);
			PLATE.FULL_PLATE.VITALS.EMPTY:QueueParam("exposure", -.25, pulse_dur/2);
		end
	end
	for tag,PLATE in pairs(oldPatients) do
		-- remove from mediview
		PLATE.inMediview = false;
		PLATE_UpdateMediMode(PLATE);
		PLATE_UpdateConfiguration(PLATE, dur);
	end
	
	if (g_medimode) then
		callback(MedimodePulse, nil, pulse_dur);
	end
end

function SortPatients(a,b)
	return (a.score > b.score);
end

-- ------------------------------------------
-- PLATE FUNCTIONS
-- ------------------------------------------
function PLATE_Create()
	local FRAME = Component.CreateFrame("TrackingFrame");
	local GROUP = Component.CreateWidget("plate", FRAME);
	
	local PLATE = {
		FRAME = FRAME,
		ANCHOR = FRAME:GetAnchor(),
		GROUP = GROUP,
		MIN_PLATE = {
			GROUP = GROUP:GetChild("min_plate"),
			ICON = MultiArt.Create(GROUP:GetChild("min_plate")),
		},
		deferred = true
	};
	
	-- one time initialization (never changes)
	PLATE.GROUP:SetDims("dock:fill");
	
	PLATE.ANCHOR:SetParam("rotation",{axis={x=0,y=0,z=1}, angle=0});
	--PLATE.ANCHOR:SetParam("scale",{x=0.7,y=0.7,z=0.7});
	
	PLATE.ANCHOR:LookAt("screen");
	PLATE.FRAME:SetBounds(-116, -48, 512, 64)
	--PLATE.FRAME:SetScaleRamp(5, 50, 1, .5);
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
	PLATE.FRAME:SetScene("world");
	
	return PLATE;
end

function PLATE_Init(PLATE, entityId)
	assert(not PLATE.tag);
	PLATE.entityId = entityId;
	PLATE.tag = tostring(entityId);
	
	if not PLATE.deferred then
		PLATE_SetupRenderTarget(PLATE)
	end
	
	local info = Game.GetTargetInfo(PLATE.entityId);
	
	if (not info) then
		info = {};
	end
	EntityRules.LoadEntityInfo(info);
	local rules = EntityRules.GetRules();
	
	if not PLATE.MAPMARKER and (rules.worldmap or rules.radar) then
		PLATE.MAPMARKER = MapMarker.Create()
	end
	
	PLATE.kill_start = nil;
	PLATE.kill_dur = nil;
	
	-- restore visibility
	PLATE.FRAME:Show(true);
	PLATE.FRAME:SetParam("alpha", 1);
	PLATE.GROUP:Show(io_Enabled)
	PLATE.GROUP:SetParam("alpha", io_Alpha)
	
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
	PLATE.FRAME:SetFocalMode(true);

	local bounds = Game.GetTargetBounds(entityId, true);
	if (bounds) then
		PLATE.prominence = (bounds.width+bounds.height+bounds.length)/6;
	else
		PLATE.prominence = 1;



	end
	PLATE.FRAME:SetParam("prominence", PLATE.prominence);
	
	--Scale the Plate up based on the size of the entity
	--og(tostring(Game.GetTargetInfo(entityId).name)..": "..PLATE.prominence.." - "..scale)
	local scale = math.min(1.5, .9 + (PLATE.prominence/50));
	PLATE.GROUP:SetParam("scaleX", scale)
	PLATE.GROUP:SetParam("scaleY", scale)
	
	-- bind map marker
	if PLATE.MAPMARKER then
		PLATE.MAPMARKER:BindToEntity(entityId);
		PLATE.MAPMARKER:GetIcon():SetParam("alpha", 1);
		
		PLATE.MAPMARKER:AddHandler("OnGotFocus", function()
			g_focused_MARKER = PLATE.MAPMARKER;
			MAP_INFO_GROUP:Show(true);
			if PLATE.deferred then
				PLATE_DeferredCreation(PLATE)
			end
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
			if PLATE.deferred then
				PLATE_DeferredCreation(PLATE)
			end
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
	PLATE.status = {};
	PLATE.vitals = {};
	PLATE.icon = nil;
	PLATE.priority = PRIORITY_NONE;
	
	return PLATE;
end

function PLATE_RecycleOut(PLATE)
	-- dump it here
	Component.RemoveRenderTarget(PLATE.tag)
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
		PLATE = PLATE_Create();
	end
	-- initilaize
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
	if (PLATE.TEXTURE_FRAME) then
		Component.RemoveFrame(PLATE.TEXTURE_FRAME);
		PLATE.TEXTURE_FRAME = nil;
	end
end

function PLATE_SlowKill(PLATE, death_dur)	
	if( PLATE == nil ) then
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

function PLATE_UpdateInfo(PLATE)
	local info = Game.GetTargetInfo(PLATE.entityId);
	
	if (not info) then
		info = {};
	end
	
	EntityRules.LoadEntityInfo(info);
	local rules = EntityRules.GetRules();
	
	local mapmarker_subtitle = info.title;
	if (not mapmarker_subtitle and info.faction) then
		--mapmarker_subtitle = Component.LookupText(info.faction);
	end	
	

	if PLATE.MAPMARKER then
		PLATE.MAPMARKER:SetTitle(rules.name);
		PLATE.MAPMARKER:SetSubtitle(mapmarker_subtitle);
		PLATE.MAPMARKER:GetIcon():SetParam("tint", rules.relationship_color);
	end
	
	PLATE.type = info.type
	
	PLATE.icon = {use_icon=rules.use_icon, texture=rules.texture, region=rules.region, icon_url=rules.icon_url};
	PLATE.MIN_PLATE.ICON:SetParam("tint", rules.relationship_color);
	
	if not PLATE.deferred then
		PLATE.FULL_PLATE.NAME:SetText(rules.name);
	
		PLATE.FULL_PLATE.VITALS.DEV:Show(rules.isDev)
	
		if info.level and info.level > 0 then
			local level = info.level
			if info.effective_level and info.effective_level > 0 then
				level = info.effective_level
			end
			PLATE.FULL_PLATE.LEVEL.GROUP:Show();
			PLATE.FULL_PLATE.LEVEL.BG:SetParam( "tint", rules.con_color );
			local show_arrow = false
			if rules.con_color == "con_skull" and (rules.hostile or info.faction == "neutral") then
				PLATE.FULL_PLATE.LEVEL.GLYPH:SetText("");
				PLATE.FULL_PLATE.LEVEL.SKULL:Show();
			else
				PLATE.FULL_PLATE.LEVEL.GLYPH:SetText(level);
				PLATE.FULL_PLATE.LEVEL.SKULL:Hide();
				PLATE.FULL_PLATE.LEVEL.GLYPH:SetTextColor( rules.con_color )
				if info.type == "character" and not info.isNpc and info.effective_level and info.level and info.effective_level ~= info.level and info.effective_level > 0 then
					show_arrow = true
					if info.effective_level < info.level then
						PLATE.FULL_PLATE.LEVEL.ARROW:SetDims("height:_; center-y:50%+4")
						PLATE.FULL_PLATE.LEVEL.ARROW:SetRegion("down")
						PLATE.FULL_PLATE.LEVEL.ARROW:SetParam("tint", "#D81D1D")
					else
						PLATE.FULL_PLATE.LEVEL.ARROW:SetDims("height:_; center-y:50%-18")
						PLATE.FULL_PLATE.LEVEL.ARROW:SetRegion("up")
						PLATE.FULL_PLATE.LEVEL.ARROW:SetParam("tint", "#4DD81D")
					end
				end
			end
			PLATE.FULL_PLATE.LEVEL.ARROW:Show(show_arrow)
		else
			PLATE.FULL_PLATE.LEVEL.GROUP:Hide();
		end
		
		if (rules.title) then
			PLATE.FULL_PLATE.TITLE:SetText(rules.title);
			PLATE.FULL_PLATE.TITLE:Show(true);
			PLATE.FULL_PLATE.NAME:SetDims("top:0; height:_");
			PLATE.FULL_PLATE.ICON:SetDims("center-y:50%; height:_")
			PLATE.FULL_PLATE.VITALS.GROUP:SetDims("top:33; height:_")
		else
			PLATE.FULL_PLATE.TITLE:SetText("");
			PLATE.FULL_PLATE.TITLE:Show(false);
			PLATE.FULL_PLATE.NAME:SetDims("center-y:60%; height:_");
			PLATE.FULL_PLATE.ICON:SetDims("center-y:60%; height:_")
			PLATE.FULL_PLATE.VITALS.GROUP:SetDims("top:30; height:_")
		end
		

		PLATE.FULL_PLATE.ICON:SetParam("tint", rules.relationship_color);
		PLATE.FULL_PLATE.TITLE:SetTextColor(rules.relationship_color);
		PLATE.FULL_PLATE.NAME:SetTextColor(rules.relationship_color);
		



		PLATE.FULL_PLATE.VITALS.OVERFILL:SetParam("glow", rules.relationship_color);
		PLATE.FULL_PLATE.VITALS.FILL:SetParam("tint", rules.relationship_color);
		--PLATE.FULL_PLATE.VITALS.EMPTY:SetParam("tint", relationship_color);
		-- set up icon
		
	end
	
	if (rules.use_icon) then
		PLATE.MIN_PLATE.ICON:Show(true);
		SetIconVisuals(PLATE.MIN_PLATE.ICON, rules)
		if not PLATE.deferred then
			PLATE.FULL_PLATE.ICON:Show(true);
			SetIconVisuals(PLATE.FULL_PLATE.ICON, rules)
			PLATE.FULL_PLATE.TEXT_GROUP:SetDims("left:20") -- adjust text dims
		end
	else
		PLATE.icon = nil;
		PLATE.MIN_PLATE.ICON:Show(false);
		if not PLATE.deferred then
			PLATE.FULL_PLATE.ICON:Show(false);
			PLATE.FULL_PLATE.TEXT_GROUP:SetDims("left:0") -- adjust text dims
		end
	end
	
	-- priority settings
	if (info.squad_member) then
		PLATE.priority = PRIORITY_HIGH;
	elseif (info.hostile or (info.type == "character" and not info.isNpc)) then
		PLATE.priority = PRIORITY_MEDIUM;
	else
		PLATE.priority = PRIORITY_LOW;
	end
	
	if PLATE.MAPMARKER then
		-- more marker set up
		if (not PLATE.MAPMARKER.texture_override) then
			SetIconVisuals(PLATE.MAPMARKER:GetIcon(), rules)
		end
		local scale = math.ceil(65*rules.marker_scale);
		PLATE.MAPMARKER:GetIcon():SetDims("width:"..scale.."%; height:"..scale.."%");

		PLATE.MAPMARKER:ShowOnWorldMap(rules.worldmap, rules.min_zoom, rules.max_zoom);
		PLATE.MAPMARKER:ShowOnRadar(rules.radar);
		PLATE.MAPMARKER:SetThemeColor(rules.relationship_color);
		PLATE.MAPMARKER:SetRadarEdgeMode(rules.edge_mode);
	end
	
	PLATE.info = info;
	PLATE_UpdateVisibility(PLATE);
end

function PLATE_UpdateStatus(PLATE, dur)
	local status = Game.GetTargetStatus(PLATE.entityId);
	if status then
		PLATE.status = status;
		
		if PLATE.MAPMARKER then
			local ICON = PLATE.MAPMARKER:GetIcon();
			if not isequal(PLATE.type, "vehicle") and (status.state == "incapacitated") then
				PLATE.MAPMARKER.texture_override = true;
				ICON:SetTexture("MapMarkers", "skull");
				ICON:ParamTo("alpha", 1, dur);
			elseif not isequal(PLATE.type, "vehicle") and (status.state == "dead") then
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

function PLATE_UpdateVitals(PLATE, dur)
	local vitals = Game.GetTargetVitals(PLATE.entityId);
	if not vitals then
		vitals = {};
	end
	if (PLATE.vitals.health_pct ~= vitals.health_pct and not PLATE.deferred) then
		if (vitals.health_pct) then
			local pct = math.ceil(vitals.health_pct*100);
			local fill_pct = math.min(100, pct);
			






			PLATE.FULL_PLATE.VITALS.FILL:MaskMoveTo("left:_; width:"..fill_pct.."%", dur, 0, "ease-in");
			PLATE.FULL_PLATE.VITALS.EMPTY:MaskMoveTo("right:_; width:"..(100-fill_pct).."%-2", dur, 0, "ease-in");
			if (pct >= 100 and not PLATE.info.hostile) then
				PLATE.FULL_PLATE.VITALS.FILL:ParamTo("alpha", 0.6, dur*2);
				PLATE.FULL_PLATE.VITALS.FILL:MoveTo("top:_; height:80%", dur);
			else
				PLATE.FULL_PLATE.VITALS.FILL:ParamTo("alpha", 1.0, dur);
				PLATE.FULL_PLATE.VITALS.FILL:MoveTo("top:_; height:100%", dur);
			end
			
			local overfill_pct = math.max(0, pct-100);
			PLATE.FULL_PLATE.VITALS.OVERFILL:MaskMoveTo("left:_; width:"..overfill_pct.."%", dur, 0, "ease-in");
			if (pct <= 100) then
				Component.FosterWidget(PLATE.FULL_PLATE.VITALS.DELTA.GROUP, PLATE.FULL_PLATE.VITALS.FILL);
			else
				Component.FosterWidget(PLATE.FULL_PLATE.VITALS.DELTA.GROUP, PLATE.FULL_PLATE.VITALS.OVERFILL);
			end
		end
	end
	PLATE.vitals = vitals;
end

function PLATE_AnimateHit(PLATE, damage, dur)
	if (PLATE.vitals.health_pct and damage ~= 0 and not PLATE.deferred) then
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

function PLATE_UpdateMediMode(PLATE)
	local dur = 0.2;
	if (PLATE.inMediview) then
		if PLATE.deferred then
			PLATE_DeferredCreation(PLATE)
		end
		PLATE.FULL_PLATE.VITALS.EMPTY:MoveTo("top:_; height:100%", dur);
	else
		if not PLATE.deferred then
			PLATE.FULL_PLATE.VITALS.EMPTY:MoveTo(PLATE.FULL_PLATE.VITALS.EMPTY:GetInitialDims(), dur);
		end
	end
end

function PLATE_UpdateConfiguration(PLATE, dur)
	-- shuffles and shows/hides elements
	
	local is_dead = (PLATE.status.state == "dead");
	local interested = ((PLATE.focus and PLATE.status.visible) or PLATE.inMediview or (g_sinView and PLATE.icon));
	local priority = PLATE.priority;
	local show_vitals = (PLATE.vitals.health_pct ~= nil and not is_dead);
	local has_vitals = (PLATE.vitals.MaxHealth ~= 0 and PLATE.vitals.MaxHealth ~= nil);
	local show_header = (PLATE.info.name ~= nil and not is_dead);
	local show_top_icon;
	
	if (not g_ShowHud) then
		interested = false;
		show_vitals = false;
		show_header = false;
		priority = PRIORITY_NONE;
	end
	
	if (interested) then
		priority = math.max(priority, PRIORITY_MEDIUM);
	else
		show_vitals = false;
		show_header = false;
	end
	
	local priority_setting = PRIORITY_SETTINGS[priority];
	show_top_icon = (g_ShowHud and PLATE.icon and not show_header and PLATE.status.inSin and PLATE.status.state ~= "dead");
	
	local dock_to_edge = priority_setting.docks_to_edge or PLATE.inMediview;
	PLATE.ANCHOR:LookAt("screen", dock_to_edge);
	
	if(g_spectating and priority >= PRIORITY_MEDIUM)then
		show_header = true;
		show_vitals = has_vitals;
		show_top_icon = false;
	end
	
	if PLATE.deferred then
		if priority_setting.cull_alpha > 0 or interested then
			PLATE_DeferredCreation(PLATE)
		end
	else	
		PLATE.FULL_PLATE.VITALS.GROUP:Show(has_vitals)
		if (show_vitals) then
			PLATE.FULL_PLATE.VITALS.GROUP:ParamTo("alpha", 1, dur);
		else
			PLATE.FULL_PLATE.VITALS.GROUP:ParamTo("alpha", 0, dur);
		end
		
		if (show_header) then
			PLATE.FULL_PLATE.GROUP:ParamTo("alpha", 1, dur);
		else
			PLATE.FULL_PLATE.GROUP:ParamTo("alpha", 0, dur);
		end		
	end
	
	PLATE.FRAME:ParamTo("cullalpha", priority_setting.cull_alpha, dur);
	
	if (show_top_icon) then
		PLATE.MIN_PLATE.GROUP:ParamTo("alpha", 1, dur);
	else
		PLATE.MIN_PLATE.GROUP:ParamTo("alpha", 0, dur);
	end
end

function PLATE_UpdateVisibility(PLATE)
	local info = PLATE.info or {};
	local suppression = d_suppressedEntities[PLATE.tag];	-- tag = tostring(entityId)
	local will_show = (not info.hidden) and (suppression ~= SUPPRESS_ALL and suppression ~= SUPPRESS_HUD);

	PLATE.FRAME:Show(will_show);

	if (not will_show) then
		-- special case: hide *GROUP* instead if this is interactable, since we need the FRAME to be visible and catch focus
		local interactInfo = Player.GetInteracteeInfo(PLATE.entityId);
		if (interactInfo and interactInfo.interactType) then
			PLATE.FRAME:Show(true);
		end
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
	local info = Game.GetTargetInfo(PLATE.entityId);
	if (not info) then
		info = {};
	end
	
	EntityRules.LoadEntityInfo(info);
	local rules = EntityRules.GetRules();
	
	w_MAP_INFO.rules = rules
	w_MAP_INFO.NAME:SetText(rules.name);
	
	if (rules.title) then
		w_MAP_INFO.TITLE:Show(true);
		w_MAP_INFO.TITLE:SetText(rules.title);
	else
		w_MAP_INFO.TITLE:Show(false);
		w_MAP_INFO.TITLE:SetText("");
	end
	
	w_MAP_INFO.ICON:SetParam("tint", rules.relationship_color);
	w_MAP_INFO.TITLE:SetTextColor(rules.relationship_color);
	w_MAP_INFO.NAME:SetTextColor(rules.relationship_color);	
	
	SetIconVisuals(w_MAP_INFO.ICON, rules)
end

function SetIconVisuals(ICON, rules)
	if type(rules) == "table" then
		if rules.icon_url and not io_UseArchTypeIcon then
			ICON:SetUrl(rules.icon_url)
		elseif rules.texture then
			ICON:SetTexture(rules.texture, rules.region)
		end
	end
end

function PLATE_DeferredCreation(PLATE)
	assert(PLATE.deferred)
	PLATE.deferred = false
	local TEXTURE_FRAME = Component.CreateFrame("TextureFrame")
	local FULL_PLATE = Component.CreateWidget("full_plate", TEXTURE_FRAME);
	
	PLATE.TEXTURE_FRAME = TEXTURE_FRAME
		
	PLATE.FULL_PLATE = {
		GROUP = PLATE.GROUP:GetChild("full_plate"),
		LEVEL = {
			GROUP = FULL_PLATE:GetChild("level"),
			BG = FULL_PLATE:GetChild("level.bg"),
			GLYPH = FULL_PLATE:GetChild("level.glyph"),
			ARROW = FULL_PLATE:GetChild("level.level_arrow"),
			SKULL = FULL_PLATE:GetChild("level.skull_icon"),
		},
		ICON = MultiArt.Create(FULL_PLATE:GetChild("header.icon")),
		TEXT_GROUP = FULL_PLATE:GetChild("header.text"),
		NAME = FULL_PLATE:GetChild("header.text.name"),
		TITLE = FULL_PLATE:GetChild("header.text.title"),
		
		VITALS = {
			GROUP = FULL_PLATE:GetChild("vitals"),
			DEV = FULL_PLATE:GetChild("vitals.dev_icon"),
			OVERFILL = FULL_PLATE:GetChild("vitals.overfill"),
			FILL = FULL_PLATE:GetChild("vitals.fill"),
			EMPTY = FULL_PLATE:GetChild("vitals.empty"),
			FLASH = FULL_PLATE:GetChild("vitals.flash"),
			DELTA = {
				GROUP = FULL_PLATE:GetChild("vitals.delta"),
				FILL = FULL_PLATE:GetChild("vitals.delta.fill"),
			},
			


		},
	}
	
	PLATE_SetupRenderTarget(PLATE)
	
	PLATE.vitals = {}
	
	PLATE_UpdateInfo(PLATE);
	PLATE_UpdateVitals(PLATE, 0);
	PLATE_UpdateStatus(PLATE, 0);
	PLATE_UpdateConfiguration(PLATE, 0.1);
	PLATE_UpdateMediMode(PLATE);	
end

function PLATE_SetupRenderTarget(PLATE)
	if not Component.CreateRenderTarget(PLATE.tag, 512, 64, 1) then
		error("Could not create render target for entity plate")
	end
	Component.SetRenderTargetRegion(PLATE.tag, 1, "full_plate", 0, 0, 512, 64) --top, left, right, bottom
	PLATE.TEXTURE_FRAME:SetTexture(PLATE.tag, "full_plate")
	PLATE.FULL_PLATE.GROUP:SetTexture(PLATE.tag, "full_plate")
end


