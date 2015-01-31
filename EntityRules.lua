
--
-- EntityRules
--	basic rules, like which icon/color/data to display for which entities under what circumstances
--   by: John Su
--

--[[

	rules = EntityRules.GetRules()				-- get current entity rules based on cached info and status
													rules = {
														title				-- title
														name				-- name
														use_icon			-- use an icon (on entityPlates)
														worldmap			-- show on world map
														radar				-- show on radar
														texture				-- texture of icon
														region				-- region of icon
														relationship_color	-- color theme of entity
														con_color			-- consider color of the entity
														marker_scale		-- scale of marker
														edge_mode			-- edge mode to use (see MapMarker.EDGE_* from lib_MapMarker)
														min_zoom
														max_zoom
													}
	
	EntityRules.LoadEntityInfo(entityInfo)		-- updates rules from provided info
	EntityRules.LoadEntityStatus(entityStatus)	-- updates rules from provided status
	
	EntityRules.LoadEntityId(entityId)			-- updates rules from provided entityId (same as LoadEntityInfo + LoadEntityStatus)
	

--]]

require "lib/lib_MapMarker";
require "lib/lib_ConColor"

-- regions map to "deployables" texture
local DEPLOYABLE_CATEGORIES = {
	["default"]					= {region="generic", scale=1.0, radar=true, worldMap=true},
	["Turret"]					= {region="turret"},
	["Mannable Turret"]			= {region="big_turret", scale=1.5},
	["Shield"]					= {region="shield"},
	["Repair Station"]			= {region="station"},
	["Charged Pulse"]			= {region="pulse"},
	["Loadout Station"]			= {texture="icons", region="battleframe_station", use_icon=false},
	["Forge"]					= {texture="icons", region="forge"},
	["Manufacturing Terminal"]	= {texture="icons", region="crafting", scale=1.5},
	["Vending Machine"]			= {texture="icons", region="slotmachine"},
	["Glider pad"]				= {texture="icons", region="glider"},
	["SIN Tower"]				= {region="sin_tower", worldMap=false},
	["Spawner"]					= {region="generic"},	-- TODO: Chosen-ify
	["Arcporter"]				= {region="generic"},
	["New You"]					= {texture="icons", region="fashion"},
	["PVP Terminal"]			= {texture="icons", region="two_flags"},
	["Army Terminal"]			= {texture="icons", region="Army"},
}

--local DEPLOYABLE_TYPE_IDS = {}

local VEHICLE_CLASSES = {
	["default"]				= {region="generic", radar = true, worldMap=true, scale=1.0},
	["Dropship"]			= {region="dropship", radar = true, worldMap=true, scale=1.75, min_zoom=0.25},
	["Battlecruiser"]		= {region="battlecruiser", radar = true, worldMap=true, scale=2.5, min_zoom=0},
	["LGV"]					= {region="lgv", radar = true, worldMap=true},
	["MGV"]					= {region="mgv", radar = true, worldMap=true, scale=1.25},
	["HGV"]					= {region="hgv", radar = true, worldMap=true, scale=1.25},
	["Cargo"]				= {region="hgv", radar = true, worldMap=true, scale=1.25},
	["Train"]				= {region="hgv", radar = true, worldMap=true, scale=1.25},
}


-- regions map to "icons" texture
local TITLE_ID_CATEGORIES = {
	["6"]				= {region="business"},	-- "Loadout Vendor"
	["8"]				= {region="business"},	-- "Calldown Vendor"
	["16"]				= {region="business"},	-- "Aesthetics Vendor"
	["17"]				= {region="business"},	-- "General Vendor"
	["45"]				= {region="business"},	-- "Vehicle Component Vendor"
	["46"]				= {region="business"},	-- "Accord Stock Gear Vendor"
	["49"]				= {region="business"},	-- "Bartender"
	["103"]				= {region="business"},	-- "Crafting Component Vendor"
	["104"]				= {region="business"},	-- "Beta Crystite Vendor"
	["105"]				= {region="business"},	-- "Classified Tech Vendor"
	["106"]				= {region="business"},	-- "Starter Component Vendor"
	["109"]				= {region="business"},	-- "Battle Arena Vendor"
	["110"]				= {region="business"},	-- "Omnidyne - M Vendor"
	["111"]				= {region="business"},	-- "Astrek Vendor"
	["112"]				= {region="business"},	-- "HelioSys Vendor"
	["113"]				= {region="business"},	-- "Kisuton Vendor"
	["132"]				= {region="business"},	-- "Beta Starter Pack Quartermaster"
	["138"]				= {region="business"},	-- "Omnidyne Vendor"
	["315"]				= {region="business"},	-- "Rep Vendors"
	["276"]				= {region="business"},	-- "Pilot Token Vendor"
	["420"]				= {region="business"},	-- "Specialty Goods"
	["421"]				= {region="business"},	-- "Weapon and Ability Modules"
	["422"]				= {region="business"},	-- "Campaign Equipment"
	
	["174"]				= {region="mystery"},	-- "Infobot"
}

local COLOR_FRIENDLY = Component.LookupColor("friendly");
local COLOR_HOSTILE = Component.LookupColor("hostile");
local COLOR_NEUTRAL = Component.LookupColor("neutral");
local COLOR_NPC = Component.LookupColor("npc");
local COLOR_SQUAD = Component.LookupColor("squad");
local COLOR_PLATOON = Component.LookupColor("platoon");
local COLOR_ARMY = Component.LookupColor("army");
local COLOR_ME = Component.LookupColor("me");

local g_entityInfo;
local g_entityStatus;

local GetNonNil;

EntityRules = {};

function EntityRules.LoadEntityId(entityId)
	EntityRules.LoadEntityInfo(Game.GetTargetInfo(entityId));
	EntityRules.LoadEntityStatus(Game.GetTargetStatus(entityId));
end

function EntityRules.LoadEntityInfo(info)
	g_entityInfo = info;
end

function EntityRules.LoadEntityStatus(status)
	g_entityStatus = status;
end

function EntityRules.GetRules()
	local info = g_entityInfo;
	local status = g_entityStatus;
	
	local myTargetId = Player.GetTargetId();
	local myTeamId = Player.GetTeamId();
	local my_effective_level = Player.GetEffectiveLevel();
	
	local myArmyId = Game.GetTargetInfo(myTargetId).armyId;
	local hostile = (info.hostile or (myTeamId and info.teamId and not isequal(myTeamId, info.teamId)))
	
	local marker_scale = 1;
	
	-- visibility
	local worldmap = true;
	local radar = true;
	
	-- labels
	local title = info.title;
	local name = info.name;

	if (info.ownerName and not title) then
		-- the owner is the title!
		title = info.ownerName;
	elseif (info.ownerId and not title) then
		-- the owner is the title!
		local ownerInfo = Game.GetTargetInfo(info.ownerId);
		if (ownerInfo and not ownerInfo.isNpc and not ownerInfo.deployableType) then
			title = ownerInfo.name;
		end
	end
	
	-- relationship color
	local relationship_color = COLOR_NEUTRAL;
	local con_color
	if info.ownerId and isequal(info.ownerId, myTargetId) then
		relationship_color = COLOR_ME;
	elseif hostile then
		relationship_color = COLOR_HOSTILE;
		local level = info.level
		if info.effective_level and info.effective_level > 0 then
			level = info.effective_level
		end
		con_color = ConColor.GetColor(level, my_effective_level)
	elseif info.squad_member then
		if Platoon.IsInPlatoon() then
			relationship_color = COLOR_PLATOON;
		else
			relationship_color = COLOR_SQUAD;
		end
	elseif info.army_member then
		relationship_color = COLOR_ARMY;
	else
		if (info.faction ~= "neutral") then
			if (info.isNpc) then
				relationship_color = COLOR_NPC;
			elseif (not info.deployableType) then
				relationship_color = COLOR_FRIENDLY;
			end
		else
			relationship_color = COLOR_NEUTRAL;
			local level = info.level
			if info.effective_level and info.effective_level > 0 then
				level = info.effective_level
			end
			con_color = ConColor.GetColor(level, my_effective_level)
		end
	end
	
	-- icon
	local use_icon = true;
	local icon_url = nil;
	local texture = "MapMarkers";
	local region = "unit";
	local done = false;
	local min_zoom = MapMarker.ZOOM_TACTICAL_MIN;
	local max_zoom = MapMarker.ZOOM_TACTICAL_MAX;
	
	if (info.type == "character" and not info.isNpc) then
		--Player Character
		done = true;
		icon_url = info.frame_url
		texture = "battleframes";
		if info.battleframe then
			region = info.battleframe;
		else
			use_icon = false
			region = "unknown";
		end
	end
	if (not done and info.title and TITLE_ID_CATEGORIES[tostring(info.titleId)]) then
		done = true;
		texture = "icons";
		region = TITLE_ID_CATEGORIES[tostring(info.titleId)].region;
	end
	if (not done and info.battleframe) then
		texture = "battleframes";
		--icon_url = info.frame_url --once npcs have chassis with good icons, then turn this back on
		region = info.battleframe;
		done = true;
	end
	if (not done and info.deployableType) then
		use_icon = false;
		worldmap = false;
		radar = false;
		local CAT;
		
		--if (info.deployableTypeId) then
		--	CAT = DEPLOYABLE_TYPE_IDS[tostring(info.deployableTypeId)];
		--end
		if (info.deployableCategory) then
			CAT = DEPLOYABLE_CATEGORIES[info.deployableCategory];
		end
		
		if (CAT) then
			done = true;
			texture = CAT.texture or "deployables";
			region = CAT.region;
			marker_scale = CAT.scale or DEPLOYABLE_CATEGORIES.default.scale;
			use_icon = GetNonNil(CAT.use_icon, use_icon);
			worldmap = not info.mapHidden;
			radar = true;
		end
	end
	if (not done and info.vehicleClass) then
		local CLASS = VEHICLE_CLASSES[info.vehicleClass] or VEHICLE_CLASSES.default;
		done = true;
		texture = "vehicles";
		region = CLASS.region;
		marker_scale = CLASS.scale or VEHICLE_CLASSES.default.scale;
		use_icon = GetNonNil(CLASS.use_icon, use_icon);
		min_zoom = CLASS.min_zoom or min_zoom
		max_zoom = CLASS.max_zoom or max_zoom
	end
	if (not done and info.thumper_name) then
		-- thumpers!
		texture = "icons";
		region = "thumper";
		marker_scale = 1.5;
		name = info.thumper_name;
		done = true;
	end
	if (not done) then
		if (info.faction and hostile) then
			texture = "factions";
			region = info.faction;
			-- when faction is neutral but is now aggroed, use gaea plate for now
			if (info.faction == "neutral") then 
				region = "gaea";
			end
		else
			use_icon = false;
			radar = (hostile);
			worldmap = (hostile);
			marker_scale = .5;
		end
	end
	
	local edge_mode = MapMarker.EDGE_NONE;
	if (info.squad_member) then
		edge_mode = MapMarker.EDGE_ICON;
		
		min_zoom = MapMarker.ZOOM_MIN;
		max_zoom = MapMarker.ZOOM_MAX;
	end
	
	if use_icon and not icon_url and not Component.GetTextureInfo(texture, region) then
		


		use_icon = false
		region = nil
	end
	
	return {
		title = title,
		name = name or "",
		use_icon = use_icon,
		worldmap = worldmap,
		radar = radar,
		icon_url = icon_url,
		texture = texture,
		region = region,
		relationship_color = relationship_color,
		con_color = con_color or relationship_color,
		edge_mode = edge_mode,
		min_zoom = min_zoom,
		max_zoom = max_zoom,
		marker_scale = marker_scale,
		hostile = hostile,
		isDev = info.isDev,
	};
end

function GetNonNil(val, default)
	if (val ~= nil) then
		return val;
	end
	return default;
end
