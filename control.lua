-- ============================================================================
-- PRESERVE PRODUCTION HISTORY ON UPGRADE
-- ============================================================================
-- Mod pour Factorio 2.0 (Space Age)
-- Conserve, cumule et affiche l'historique complet de production par niveau.
-- ============================================================================

-- Configuration
local DEBUG_MODE = false -- Mettez à true pour activer les logs détaillés dans factorio-current.log

-- Helper pour récupérer de manière sécurisée la table globale de transferts
local function get_pending_replacements()
    if not storage.pending_replacements then
        storage.pending_replacements = {}
    end
    return storage.pending_replacements
end

-- Formate la position géométrique de manière ultra-rapide (concaténation native)
local function get_position_key(surface_index, position)
    return surface_index .. "_" .. position.x .. "_" .. position.y
end

-- Formate les nombres avec des séparateurs de milliers pour un rendu premium (ex: 1 990 553)
local function format_number(n)
    local formatted = tostring(n)
    while true do  
        local k
        formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", '%1 %2')
        if (k == 0) then
            break
        end
    end
    return formatted
end

-- Garde en mémoire le dernier tick nettoyé pour éviter des nettoyages redondants dans le même tick
local last_cleaned_tick = -1

local function clean_obsolete_ticks(current_tick)
    if last_cleaned_tick == current_tick then return end
    last_cleaned_tick = current_tick
    
    local pending = get_pending_replacements()
    for tick, _ in pairs(pending) do
        if tick < current_tick then
            pending[tick] = nil
        end
    end
end

-- ============================================================================
-- HANDLERS DE CYCLES DE VIE DES ENTITÉS
-- ============================================================================

-- Handler appelé lorsqu'une machine d'assemblage, four ou silo est démonté/détruit
local function on_entity_mined(event)
    local entity = event.entity
    if not entity or not entity.valid then return end
    
    local tick = event.tick
    clean_obsolete_ticks(tick)
    
    local unit_number = entity.unit_number
    if not unit_number then return end
    
    -- Récupération de l'historique existant de la machine
    storage.machine_history = storage.machine_history or {}
    local history = storage.machine_history[unit_number]
    
    local sum_previous = 0
    if not history then
        history = {}
    else
        -- Calcul de la production cumulée des paliers précédents
        for _, entry in ipairs(history) do
            sum_previous = sum_previous + entry.products
        end
        -- Suppression pour éviter les fuites de mémoire
        storage.machine_history[unit_number] = nil
    end
    
    -- Lecture ultra-sécurisée du compteur cumulé de cycles actuels
    local success, current_total = pcall(function() return entity.products_finished end)
    
    if success and current_total and current_total > sum_previous then
        local active_products = current_total - sum_previous
        -- On ajoute la production réelle de cette machine à l'historique
        table.insert(history, {
            name = entity.localised_name,
            products = active_products
        })
    end
    
    -- Stockage transitoire uniquement s'il y a un historique à préserver
    if #history > 0 then
        local pos_key = get_position_key(entity.surface.index, entity.position)
        local pending = get_pending_replacements()
        
        pending[tick] = pending[tick] or {}
        pending[tick][pos_key] = history
        
        if DEBUG_MODE then
            log(string.format("[PPH] Captured history with %d entries from %s at tick %d", #history, entity.name, tick))
        end
    end
end

-- Handler appelé lorsqu'une machine d'assemblage, four ou silo est construit/posé
local function on_entity_built(event)
    -- Sécurité API : le joueur utilise created_entity, les robots/scripts/plateformes utilisent entity
    local entity = event.entity or event.created_entity
    if not entity or not entity.valid then return end
    
    local tick = event.tick
    local pending = get_pending_replacements()
    local tick_data = pending[tick]
    
    if tick_data then
        local pos_key = get_position_key(entity.surface.index, entity.position)
        local stored_history = tick_data[pos_key]
        
        if stored_history then
            local unit_number = entity.unit_number
            if unit_number then
                -- Attribution de l'historique cumulé au nouvel identifiant d'entité
                storage.machine_history = storage.machine_history or {}
                storage.machine_history[unit_number] = stored_history
                
                -- Calcul du total cumulé de tous les paliers
                local total_cumulative = 0
                for _, entry in ipairs(stored_history) do
                    total_cumulative = total_cumulative + entry.products
                end
                
                -- Restauration du compteur cumulé directement dans l'entité active
                pcall(function() entity.products_finished = total_cumulative end)
                
                if DEBUG_MODE then
                    log(string.format("[PPH] Restored cumulative products %d to %s (unit %d) at tick %d", total_cumulative, entity.name, unit_number, tick))
                end
            end
            
            -- Nettoyage immédiat du stockage transitoire
            tick_data[pos_key] = nil
            if not next(tick_data) then
                pending[tick] = nil
            end
        end
    end
end

-- Enregistrement des filtres d'entités
local entity_filters = {
    {filter = "type", type = "assembling-machine"},
    {filter = "type", type = "furnace"},
    {filter = "type", type = "rocket-silo"}
}

-- Événements de démontage
script.on_event(defines.events.on_player_mined_entity, on_entity_mined, entity_filters)
script.on_event(defines.events.on_robot_mined_entity, on_entity_mined, entity_filters)
script.on_event(defines.events.on_space_platform_mined_entity, on_entity_mined, entity_filters)
script.on_event(defines.events.script_raised_destroy, on_entity_mined, entity_filters)

-- Événements de construction
script.on_event(defines.events.on_built_entity, on_entity_built, entity_filters)
script.on_event(defines.events.on_robot_built_entity, on_entity_built, entity_filters)
script.on_event(defines.events.on_space_platform_built_entity, on_entity_built, entity_filters)
script.on_event(defines.events.script_raised_built, on_entity_built, entity_filters)

-- ============================================================================
-- INTERFACE GRAPHIQUE (GUI RELATIVE DYNAMIQUE)
-- ============================================================================

-- Crée ou met à jour l'interface graphique pour un joueur donné
local function create_history_gui(player, entity)
    local relative = player.gui.relative
    local frame = relative.pph_production_history_frame
    
    -- Récupération de l'historique et du total cumulé actif
    local history = storage.machine_history and storage.machine_history[entity.unit_number]
    local current_total = entity.products_finished or 0
    
    -- Calcul de la production cumulée précédente
    local sum_previous = 0
    if history then
        for _, entry in ipairs(history) do
            sum_previous = sum_previous + entry.products
        end
    end
    
    -- Production spécifique de la machine active
    local current_products = current_total - sum_previous
    if current_products < 0 then current_products = 0 end
    
    -- Si aucun historique et aucune production sur la machine active, on n'affiche rien (on détruit si présent)
    if (not history or #history == 0) and current_products == 0 then
        if frame then frame.destroy() end
        return
    end
    
    -- Détermination du type de GUI à ancrer
    local gui_type
    if entity.type == "assembling-machine" then
        gui_type = defines.relative_gui_type.assembling_machine_gui
    elseif entity.type == "furnace" then
        gui_type = defines.relative_gui_type.furnace_gui
    elseif entity.type == "rocket-silo" then
        gui_type = defines.relative_gui_type.rocket_silo_gui
    end
    
    if not gui_type then return end
    
    -- Si la frame n'existe pas, on la crée
    if not frame or not frame.valid then
        frame = relative.add{
            type = "frame",
            name = "pph_production_history_frame",
            direction = "vertical",
            anchor = {
                gui = gui_type,
                position = defines.relative_gui_position.right
            }
        }
    else
        -- On vide le contenu existant pour le reconstruire proprement (évite les duplications)
        frame.clear()
    end
    
    -- Titre du panneau
    local title_flow = frame.add{type = "flow", direction = "horizontal"}
    title_flow.add{
        type = "label",
        caption = "Historique de Production",
        style = "frame_title"
    }
    
    -- Conteneur interne au style sombre et épuré nativement intégré
    local content_frame = frame.add{
        type = "frame",
        direction = "vertical",
        style = "inside_deep_frame"
    }
    content_frame.style.padding = 10
    content_frame.style.minimal_width = 240
    
    -- Liste des paliers précédents (historiques)
    if history then
        for _, entry in ipairs(history) do
            local row = content_frame.add{type = "flow", direction = "horizontal"}
            row.style.vertical_align = "center"
            
            row.add{
                type = "label",
                caption = entry.name
            }
            row.add{
                type = "label",
                caption = " : " .. format_number(entry.products),
                style = "bold_label"
            }
        end
    end
    
    -- Palier en cours d'utilisation (actif)
    if current_products > 0 then
        local row = content_frame.add{type = "flow", direction = "horizontal"}
        row.style.vertical_align = "center"
        
        row.add{
            type = "label",
            caption = entity.localised_name,
            style = "bold_label"
        }
        row.add{
            type = "label",
            caption = " : " .. format_number(current_products) .. " [actif]"
        }
        -- Légère coloration pour faire ressortir la ligne active (Orange Factorio)
        row.children[1].style.font_color = {r = 1, g = 0.74, b = 0.4}
        row.children[2].style.font_color = {r = 1, g = 0.74, b = 0.4}
    end
    
    -- Total cumulé complet (pour faire le lien parfait avec l'encart officiel)
    if current_total > 0 then
        local line = content_frame.add{type = "line", direction = "horizontal"}
        line.style.top_margin = 5
        line.style.bottom_margin = 5
        
        local row = content_frame.add{type = "flow", direction = "horizontal"}
        row.style.vertical_align = "center"
        
        row.add{
            type = "label",
            caption = "Total cumulé",
            style = "bold_label"
        }
        row.add{
            type = "label",
            caption = " : " .. format_number(current_total),
            style = "bold_label"
        }
        -- Coloration bleu clair premium
        row.children[1].style.font_color = {r = 0.4, g = 0.8, b = 1.0}
        row.children[2].style.font_color = {r = 0.4, g = 0.8, b = 1.0}
    end
end

-- Handler appelé à l'ouverture d'un GUI
local function on_gui_opened(event)
    local entity = event.entity
    if not entity or not entity.valid then return end
    
    if entity.type == "assembling-machine" or entity.type == "furnace" or entity.type == "rocket-silo" then
        local player = game.get_player(event.player_index)
        if player and player.valid then
            create_history_gui(player, entity)
            
            -- Enregistrement pour les mises à jour dynamiques en temps réel
            storage.active_guis = storage.active_guis or {}
            storage.active_guis[event.player_index] = entity
        end
    end
end

-- Handler appelé à la fermeture d'un GUI
local function on_gui_closed(event)
    local entity = event.entity
    if not entity or not entity.valid then return end
    
    if entity.type == "assembling-machine" or entity.type == "furnace" or entity.type == "rocket-silo" then
        if storage.active_guis then
            storage.active_guis[event.player_index] = nil
        end
    end
end

script.on_event(defines.events.on_gui_opened, on_gui_opened)
script.on_event(defines.events.on_gui_closed, on_gui_closed)

-- Mise à jour dynamique de l'interface en temps réel toutes les 30 ticks (0,5 seconde)
script.on_nth_tick(30, function()
    if not storage.active_guis then return end
    
    for player_index, entity in pairs(storage.active_guis) do
        local player = game.get_player(player_index)
        if player and player.valid and entity and entity.valid then
            local relative = player.gui.relative
            local frame = relative.pph_production_history_frame
            if frame and frame.valid then
                create_history_gui(player, entity)
            else
                -- L'interface a été fermée, on nettoie la table
                storage.active_guis[player_index] = nil
            end
        else
            storage.active_guis[player_index] = nil
        end
    end
end)
