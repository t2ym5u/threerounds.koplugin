local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputDialog     = require("ui/widget/inputdialog")
local Size            = require("ui/size")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("i18n")
local T               = require("ffi/util").template

-- French and English plurals: "1 point", "0 point" (fr) / "0 points" (en).
local function singular(n)
    if _.lang() == "fr" then return n >= -1 and n <= 1 end
    return n == 1 or n == -1
end

local MenuHelper = require("menu_helper")
local ScreenBase = require("screen_base")
local Game       = lrequire("game")
local W          = lrequire("widgets")

local DeviceScreen = Device.screen

local DECK_SIZES   = { 30, 40, 60 }
local TURN_TIMES   = { 30, 45, 60 }
local MAX_RECENT   = 150

local GAME_RULES_EN = [[
Three Rounds — Rules

Two to four teams play three rounds with the SAME deck of cards: famous people, characters, places…

• Round 1 — Describe: say anything except the name itself.
• Round 2 — One word: a single word per card, nothing more.
• Round 3 — Mime: no words at all, gestures and sounds only.

On a turn, one player of the active team holds the reader and makes their team guess as many cards as possible before the timer ends. Tap Found when the team gets it (+1, the card leaves the pool) or Pass to send it to the bottom of the pool (by default only in rounds 2 and 3). Undo takes back the last tap.

When the timer ends, the reader shows a hand-over screen: pass it to the next team's player, who taps Ready. When the pool is empty the round is over; the same cards come back for the next round, which gets easier since everyone has heard them. After round 3, the team with the most cards found wins.

Settings: teams and their names, number of cards (30, 40 or 60), turn length, when passing is allowed, card themes.
]]

local GAME_RULES_FR = [[
Trois manches — Règles

Deux à quatre équipes jouent trois manches avec le MÊME paquet de cartes : personnages célèbres, héros de fiction, lieux…

• Manche 1 — Description : on dit tout ce qu'on veut, sauf le nom lui-même.
• Manche 2 — Un seul mot : un mot par carte, pas un de plus.
• Manche 3 — Mime : aucun mot, seulement des gestes et des bruitages.

À chaque tour, un joueur de l'équipe active tient la liseuse et fait deviner un maximum de cartes avant la fin du chrono. Touchez « Trouvé » quand l'équipe trouve (+1, la carte quitte la pioche) ou « Passer » pour la remettre sous la pioche (par défaut seulement aux manches 2 et 3). « Annuler » reprend la dernière touche.

Quand le chrono sonne, un écran de passage s'affiche : donnez la liseuse au joueur de l'équipe suivante, qui touche « Prêt ». Quand la pioche est vide, la manche est finie ; les mêmes cartes reviennent pour la manche suivante, plus facile puisque tout le monde les a entendues. Après la manche 3, l'équipe qui a trouvé le plus de cartes gagne.

Réglages : équipes et leurs noms, nombre de cartes (30, 40 ou 60), durée d'un tour, quand on peut passer, thèmes des cartes.
]]

local function defaultLang()
    return _.lang() == "fr" and "fr" or "en"
end

local function loadBank(lang)
    local chunk = loadfile(_dir .. "cards_" .. lang .. ".lua")
    local ok, data = pcall(chunk or error)
    return ok and type(data) == "table" and data or {}
end

local function themeLabel(id)
    local labels = {
        history = _("Historical figures"),
        science = _("Scientists & explorers"),
        inventions = _("Inventions"),
        monuments = _("Monuments of the world"),
        food    = _("Food & dishes"),
        animals = _("Famous animals"),
        kids    = _("Kids (easy)"),
        arts    = _("Arts & letters"),
        music   = _("Musicians"),
        fiction = _("Stories & games"),
        screen  = _("Film & TV"),
        places  = _("Countries & cities"),
        sport   = _("Sports stars"),
        myth    = _("Myths & legends"),
    }
    return labels[id] or id
end

local function roundRule(r)
    if r == 1 then return _("Describe freely") end
    if r == 2 then return _("One word only") end
    return _("Mime only")
end

local function passLabel(id)
    if id == "all" then return _("All rounds") end
    if id == "never" then return _("Never") end
    return _("Rounds 2–3")
end

-- ---------------------------------------------------------------------------

local ThreeRoundsScreen = ScreenBase:extend{}

function ThreeRoundsScreen:init()
    local plugin = self.plugin
    self.lang      = plugin:getSetting("lang", defaultLang())
    self.duration  = plugin:getSetting("duration", 45)
    self.deck_size = plugin:getSetting("deck_size", 40)
    self.themes    = self:_loadThemes()
    self.bank      = loadBank(self.lang)
    self.game = Game.new{ teams = self:_teamNames(plugin:getSetting("nb_teams", 2)),
                          pass_rule = plugin:getSetting("pass_rule", "r23") }
    self.game:load(plugin:loadState())
    ScreenBase.init(self)
end

function ThreeRoundsScreen:_teamNames(n)
    local saved = self.plugin:getSetting("team_names", {})
    local out = {}
    for i = 1, n do out[i] = saved[i] or T(_("Team %1"), i) end
    return out
end

function ThreeRoundsScreen:_loadThemes()
    local saved = self.plugin:getSetting("themes", nil)
    if type(saved) ~= "table" or #saved == 0 then return nil end
    local set = {}
    for _i, t in ipairs(saved) do set[t] = true end
    return set
end

function ThreeRoundsScreen:serializeState()
    return self.game:serialize()
end

function ThreeRoundsScreen:_save()
    self.plugin:saveState(self:serializeState())
end

function ThreeRoundsScreen:_redraw()
    self:buildLayout()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

-- ---------------------------------------------------------------------------
-- Timer
-- ---------------------------------------------------------------------------

function ThreeRoundsScreen:_startCountdown()
    self._tick_gen = (self._tick_gen or 0) + 1
    local gen = self._tick_gen
    UIManager:scheduleIn(1, function() self:_onTick(gen) end)
end

function ThreeRoundsScreen:_stopCountdown()
    self._tick_gen = (self._tick_gen or 0) + 1
end

function ThreeRoundsScreen:_timerText()
    local t = self.time_left or 0
    return string.format("%d:%02d", math.floor(t / 60), t % 60)
end

function ThreeRoundsScreen:_onTick(gen)
    if gen ~= self._tick_gen or self.game.phase ~= "turn" then return end
    self.time_left = math.max(0, (self.time_left or 0) - 1)
    if self.time_left <= 0 then
        self:onTimeUp()
        return
    end
    -- Only the timer changes: refresh just its frame.
    if self.timer_widget then
        self.timer_widget:setText(self:_timerText())
        UIManager:setDirty(self, function()
            return "fast", self.timer_frame and self.timer_frame.dimen or self.dimen
        end)
    end
    UIManager:scheduleIn(1, function() self:_onTick(gen) end)
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

function ThreeRoundsScreen:onStartGame()
    local recent = {}
    for _i, name in ipairs(self.plugin:getSetting("recent_cards", {})) do recent[name] = true end
    local deck = Game.pickDeck(self.bank, self.themes, self.deck_size, recent)
    if #deck == 0 then
        self:showMessage(_("No cards for these themes."))
        return
    end
    -- Remember this deck so the next game starts with other cards.
    local list = {}
    for _i, c in ipairs(deck) do list[#list + 1] = c.text end
    for _i, name in ipairs(self.plugin:getSetting("recent_cards", {})) do
        if #list >= MAX_RECENT then break end
        list[#list + 1] = name
    end
    self.plugin:saveSetting("recent_cards", list)
    self.game:startGame(deck)
    self:_save()
    self:_redraw()
end

function ThreeRoundsScreen:onReady()
    self.game:startTurn()
    self.time_left = self.duration
    self:_redraw()
    self:_startCountdown()
end

function ThreeRoundsScreen:onFound()
    local ended = self.game:found()
    if ended then self:_stopCountdown() end
    self:_save()
    self:_redraw()
end

function ThreeRoundsScreen:onPass()
    if self.game:pass() then self:_redraw() end
end

function ThreeRoundsScreen:onUndo()
    if self.game:undo() then
        self:_save()
        self:_redraw()
    end
end

function ThreeRoundsScreen:onTimeUp()
    self:_stopCountdown()
    self.game:endTurn()
    self:_save()
    self:_redraw()
    self:showMessage(_("Time's up!"), 2)
end

function ThreeRoundsScreen:onNextRound()
    self.game:nextRound()
    self:_save()
    self:_redraw()
end

function ThreeRoundsScreen:onNewGame()
    self:_stopCountdown()
    local names = {}
    for i, t in ipairs(self.game.teams) do names[i] = t.name end
    self.game:newGame(names)
    self:_save()
    self:_redraw()
end

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

function ThreeRoundsScreen:_picker(title, items, current, on_select)
    MenuHelper.openPickerMenu{
        title = title, items = items, current_id = current, parent = self,
        on_select = function(id)
            on_select(id)
            self:_redraw()
        end,
    }
end

function ThreeRoundsScreen:openLangMenu()
    self:_picker(_("Language"),
        { { id = "fr", text = "Français" }, { id = "en", text = "English" } }, self.lang,
        function(lang)
            self.lang = lang
            self.plugin:saveSetting("lang", lang)
            self.bank = loadBank(lang)
        end)
end

-- A different number of teams starts a new game.
function ThreeRoundsScreen:openTeamsMenu()
    local items = {}
    for n = 2, 4 do items[#items + 1] = { id = n, text = T(_("%1 teams"), n) } end
    self:_picker(_("Teams"), items, #self.game.teams, function(n)
        self.plugin:saveSetting("nb_teams", n)
        if n ~= #self.game.teams then
            self._stopCountdown(self)
            self.game:newGame(self:_teamNames(n))
            self:_save()
        end
    end)
end

function ThreeRoundsScreen:openTeamNamesDialog()
    local names = {}
    for i, t in ipairs(self.game.teams) do names[i] = t.name end
    local dialog
    dialog = InputDialog:new{
        title = _("Team names"),
        description = _("One name per line."),
        input = table.concat(names, "\n"),
        allow_newline = true,
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("OK"), callback = function()
                local text = dialog:getInputText() or ""
                UIManager:close(dialog)
                self:applyTeamNames(text)
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Renames the teams in place (scores kept); extra lines are ignored.
function ThreeRoundsScreen:applyTeamNames(text)
    local names = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" then names[#names + 1] = line end
    end
    local saved = self.plugin:getSetting("team_names", {})
    for i, t in ipairs(self.game.teams) do
        if names[i] then t.name = names[i]; saved[i] = names[i] end
    end
    self.plugin:saveSetting("team_names", saved)
    self:_save()
    self:_redraw()
end

function ThreeRoundsScreen:openDeckMenu()
    local items = {}
    for _i, n in ipairs(DECK_SIZES) do items[#items + 1] = { id = n, text = T(_("%1 cards"), n) } end
    self:_picker(_("Cards"), items, self.deck_size, function(n)
        self.deck_size = n
        self.plugin:saveSetting("deck_size", n)
    end)
end

function ThreeRoundsScreen:openTimerMenu()
    local items = {}
    for _i, d in ipairs(TURN_TIMES) do items[#items + 1] = { id = d, text = T(_("%1 s"), d) } end
    self:_picker(_("Timer"), items, self.duration, function(d)
        self.duration = d
        self.plugin:saveSetting("duration", d)
    end)
end

function ThreeRoundsScreen:openPassMenu()
    local items = {}
    for _i, id in ipairs(Game.PASS_ORDER) do items[#items + 1] = { id = id, text = passLabel(id) } end
    self:_picker(_("Passing"), items, self.game.pass_rule, function(id)
        self.game.pass_rule = id
        self.plugin:saveSetting("pass_rule", id)
    end)
end

function ThreeRoundsScreen:_themesText()
    if not self.themes then return T(_("Themes: %1"), _("Default")) end
    local n = 0
    for _i, t in ipairs(Game.THEMES) do if self.themes[t] then n = n + 1 end end
    return T(_("Themes: %1"), n .. "/" .. #Game.THEMES)
end

-- Multi-select: re-opens after each toggle.
function ThreeRoundsScreen:openThemesMenu()
    local items = { { id = "__default__",
        text = (self.themes and "  " or "★ ") .. _("Default (all but Kids)") } }
    local set = self.themes or Game.DEFAULT_THEMES
    for _i, t in ipairs(Game.THEMES) do
        local on = set[t]
        items[#items + 1] = { id = t, text = (on and "✓ " or "○ ") .. themeLabel(t)
            .. string.format("  (%d)", #(self.bank[t] or {})) }
    end
    MenuHelper.openPickerMenu{
        title = _("Themes"), items = items, parent = self,
        on_select = function(id)
            self:toggleTheme(id)
            self:_redraw()
            self:openThemesMenu()
        end,
    }
end

function ThreeRoundsScreen:toggleTheme(id)
    if id == "__default__" then
        self.themes = nil
    else
        local set = {}
        for t in pairs(self.themes or Game.DEFAULT_THEMES) do set[t] = true end
        set[id] = not set[id] or nil
        local default, any = true, false
        for _i, t in ipairs(Game.THEMES) do
            if set[t] then any = true end
            if (set[t] or false) ~= (Game.DEFAULT_THEMES[t] or false) then default = false end
        end
        if default then
            self.themes = nil
        elseif any then
            self.themes = set
        end   -- the last theme can't be switched off
    end
    local list = {}
    if self.themes then
        for _i, t in ipairs(Game.THEMES) do if self.themes[t] then list[#list + 1] = t end end
    end
    self.plugin:saveSetting("themes", list)
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

function ThreeRoundsScreen:isRoundOver()
    return self.game:isGameOver()
end

function ThreeRoundsScreen:getRoundOverButtons()
    return { self:_bigButton(_("New game"), function() self:onNewGame() end) }
end

function ThreeRoundsScreen:_bigButton(text, callback, extra, scale)
    local b = { text = text, callback = callback,
                height = DeviceScreen:scaleBySize(64 * (scale or 1)),
                font_size = math.floor(24 * math.min(scale or 1, 1.25)) }
    for k, v in pairs(extra or {}) do b[k] = v end
    return b
end

function ThreeRoundsScreen:_titleBar()
    local g = self.game
    return self:buildTitleBar(_("Three Rounds"), function()
        return {
            { text = _("New game"), callback = function() self:onNewGame() end },
            { text = T(_("Language: %1"), self.lang:upper()), callback = function() self:openLangMenu() end },
            { text = T(_("Teams: %1"), #g.teams), callback = function() self:openTeamsMenu() end },
            { text = _("Team names"), callback = function() self:openTeamNamesDialog() end },
            { text = T(_("Cards: %1"), self.deck_size), callback = function() self:openDeckMenu() end },
            { text = T(_("Timer: %1"), T(_("%1 s"), self.duration)), callback = function() self:openTimerMenu() end },
            { text = T(_("Passing: %1"), passLabel(g.pass_rule)), callback = function() self:openPassMenu() end },
            { text = self:_themesText(), callback = function() self:openThemesMenu() end },
            self:makeRulesButtonConfig(GAME_RULES_EN, GAME_RULES_FR),
        }
    end)
end

function ThreeRoundsScreen:_controls(rows, extra_top)
    self.status_text:setMaxWidth(self:getControlsWidth())
    local g = VerticalGroup:new{ align = "center" }
    if extra_top then
        g[#g + 1] = extra_top
        g[#g + 1] = VerticalSpan:new{ width = Size.span.vertical_large }
    end
    g[#g + 1] = self.status_text
    g[#g + 1] = VerticalSpan:new{ width = Size.span.vertical_large }
    g[#g + 1] = self:buildActionBar(rows)
    return g
end

function ThreeRoundsScreen:_place(title_bar, content, controls)
    if self:isLandscape() then
        self:buildLandscapeLayout(title_bar, HorizontalGroup:new{
            align = "center",
            content,
            HorizontalSpan:new{ width = self:getGutter() },
            controls,
        })
    else
        self:buildPortraitLayout(title_bar, content,
            VerticalGroup:new{ align = "center", controls, VerticalSpan:new{ width = self:getGutter() } })
    end
end

function ThreeRoundsScreen:buildLayout()
    local phase = self.game.phase
    self.timer_widget, self.timer_frame = nil, nil
    if phase == "turn" then
        self:_buildTurn()
    elseif phase == "handover" then
        self:_buildHandover()
    elseif phase == "round_end" or phase == "game_over" then
        self:_buildScores()
    else
        self:_buildSetup()
    end
    self[1] = self.layout
    self:updateStatus()
end

local function para(text, face, width)
    return TextBoxWidget:new{ text = text, face = face, width = width, alignment = "center" }
end

function ThreeRoundsScreen:_teamTable(width, max_h)
    local g = self.game
    local played = g.phase == "setup" and 0 or g.round
    local headers = { "" }
    for r = 1, played do headers[#headers + 1] = T(_("R%1"), r) end
    headers[#headers + 1] = _("Total")
    local rows = {}
    local order = played > 0 and g:ranking() or nil
    for i = 1, #g.teams do
        local t = g.teams[order and order[i] or i]
        local idx = order and order[i] or i
        local row = { t.name }
        for r = 1, played do row[#row + 1] = t.scores[r] end
        row[#row + 1] = g:total(idx)
        rows[i] = row
    end
    return W.scoreTable(headers, rows, width, max_h)
end

function ThreeRoundsScreen:_buildSetup()
    local title_bar = self:_titleBar()
    local controls = self:_controls({ self:_bigButton(_("Start game"), function() self:onStartGame() end) })
    local bw, bh = self:getBoardBudget(title_bar, controls)
    local short = math.min(bw, bh)
    local vs = Size.span.vertical_large
    local head = W.fitLine(_("Three Rounds"), short * 0.1, bw, true)
    local rounds = VerticalGroup:new{ align = "center" }
    for r = 1, Game.ROUNDS do
        rounds[#rounds + 1] = W.fitLine(T(_("Round %1: %2"), r, roundRule(r)), short * 0.05, bw)
    end
    local info = para(self:joinStatus(T(_("%1 cards"), self.deck_size),
        T(_("%1 s per turn"), self.duration), T(_("Passing: %1"), passLabel(self.game.pass_rule))),
        Font:getFace("infofont"), bw)
    local used = head:getSize().h + rounds:getSize().h + info:getSize().h + 5 * vs
    local content = VerticalGroup:new{
        align = "center",
        head, VerticalSpan:new{ width = vs }, rounds, VerticalSpan:new{ width = vs * 2 },
        info, VerticalSpan:new{ width = vs * 2 },
        self:_teamTable(math.floor(bw * 0.8), bh - used),
    }
    self:_place(title_bar, content, controls)
end

-- Neutral screen between turns: no card visible until Ready is tapped.
function ThreeRoundsScreen:_buildHandover()
    local g = self.game
    local team = g.teams[g.current_team]
    local title_bar = self:_titleBar()
    local controls = self:_controls({ self:_bigButton(_("Ready"), function() self:onReady() end, nil, 1.4) })
    local bw, bh = self:getBoardBudget(title_bar, controls)
    local short = math.min(bw, bh)
    local vs = Size.span.vertical_large
    local content = VerticalGroup:new{ align = "center" }
    if g.last_turn then
        content[#content + 1] = para(T(singular(g.last_turn.found) and _("%1 found %2 card.") or _("%1 found %2 cards."), g.teams[g.last_turn.team].name,
            g.last_turn.found), Font:getFace("infofont"), bw)
        content[#content + 1] = VerticalSpan:new{ width = vs * 2 }
    end
    content[#content + 1] = W.fitLine(T(_("Round %1 of %2"), g.round, Game.ROUNDS), short * 0.06, bw)
    content[#content + 1] = W.fitLine(roundRule(g.round), short * 0.09, bw, true)
    content[#content + 1] = VerticalSpan:new{ width = vs * 3 }
    content[#content + 1] = para(_("Pass the reader to"), Font:getFace("infofont"), bw)
    content[#content + 1] = VerticalSpan:new{ width = vs }
    content[#content + 1] = W.fitLine(team.name, short * 0.13, bw, true)
    content[#content + 1] = VerticalSpan:new{ width = vs * 2 }
    content[#content + 1] = para(_("One player holds the reader and makes the team guess. Tap Ready to show the first card and start the timer."),
        Font:getFace("smallinfofont"), math.floor(bw * 0.9))
    self:_place(title_bar, content, controls)
end

function ThreeRoundsScreen:_buildTurn()
    local g = self.game
    local card = g:currentCard()
    local land = self:isLandscape()
    local title_bar = self:_titleBar()
    local rows = {
        { self:_bigButton("✓ " .. _("Found"), function() self:onFound() end, nil, 1.6) },
        {
            self:_bigButton("→ " .. _("Pass"), function() self:onPass() end,
                { enabled = g:canPass() }),
            self:_bigButton("↶ " .. _("Undo"), function() self:onUndo() end,
                { enabled = g:canUndo() }),
        },
    }
    local short_screen = math.min(self.dimen.w, self.dimen.h)
    local timer_px = math.floor(short_screen * (land and 0.11 or 0.12))
    self.timer_widget = TextWidget:new{ text = self:_timerText(), face = W.pxFace(timer_px, true),
                                        bold = true }
    self.timer_frame = FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = W.fitLine("0:00", timer_px, 10000, true):getSize().w
                                  + Size.padding.large,
                              h = self.timer_widget:getSize().h },
            self.timer_widget,
        },
    }
    local header = VerticalGroup:new{
        align = "center",
        self.timer_frame,
        W.fitLine(T(_("Round %1: %2"), g.round, roundRule(g.round)),
            Font:getFace("infofont").size, self:getControlsWidth()),
    }
    local controls = self:_controls(rows, land and header or nil)
    local bw, bh = self:getBoardBudget(title_bar, controls)
    local vs = Size.span.vertical_large
    local card_h = bh - (land and 0 or (header:getSize().h + vs))
    local pad = Size.padding.large
    local inner_w = bw - 2 * (pad + Size.border.thick)
    local inner_h = card_h - 2 * (pad + Size.border.thick)
    local theme = TextWidget:new{ text = card and themeLabel(card.theme) or "",
                                  face = Font:getFace("smallinfofont") }
    local name = W.fitParagraph(card and card.text or "?", math.min(inner_w * 0.16, inner_h * 0.3),
        inner_w, inner_h - theme:getSize().h - vs * 2, true)
    local card_frame = FrameContainer:new{
        bordersize = Size.border.thick, padding = pad, margin = 0, radius = Size.radius.window,
        CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = inner_h },
            VerticalGroup:new{ align = "center", theme, VerticalSpan:new{ width = vs * 2 }, name },
        },
    }
    local content
    if land then
        content = card_frame
    else
        content = VerticalGroup:new{ align = "center", header, VerticalSpan:new{ width = vs }, card_frame }
    end
    self:_place(title_bar, content, controls)
end

function ThreeRoundsScreen:_buildScores()
    local g = self.game
    local over = g:isGameOver()
    local title_bar = self:_titleBar()
    local controls = self:_controls({
        self:_bigButton(T(_("Start round %1"), g.round + 1), function() self:onNextRound() end),
    })
    local bw, bh = self:getBoardBudget(title_bar, controls)
    local short = math.min(bw, bh)
    local vs = Size.span.vertical_large
    local head = W.fitLine(over and _("Final scores") or T(_("Round %1 over"), g.round),
        short * 0.1, bw, true)
    local line
    if over then
        local w = g:winner()
        line = w and T(_("Winner: %1!"), g.teams[w].name) or _("It's a tie!")
    else
        line = T(_("Next: %1"), roundRule(g.round + 1))
    end
    local sub = para(line, Font:getFace("infofont"), bw)
    local used = head:getSize().h + sub:getSize().h + 3 * vs
    local content = VerticalGroup:new{
        align = "center",
        head, VerticalSpan:new{ width = vs }, sub, VerticalSpan:new{ width = vs * 2 },
        self:_teamTable(math.floor(bw * 0.9), bh - used),
    }
    self:_place(title_bar, content, controls)
end

function ThreeRoundsScreen:updateStatus(msg)
    if msg then ScreenBase.updateStatus(self, msg); return end
    local g = self.game
    local s
    if g.phase == "turn" then
        s = self:joinStatus(T(_("Cards left: %1"), #g.pool), T(_("Found: %1"), g.turn_found or 0))
    elseif g.phase == "handover" then
        s = self:joinStatus(T(_("Cards left: %1"), #g.pool), T(_("Round %1 of %2"), g.round, Game.ROUNDS))
    elseif g.phase == "setup" then
        s = self:joinStatus(T(_("Teams: %1"), #g.teams), self:_themesText())
    else
        s = T(_("Cards: %1"), #g.deck)
    end
    ScreenBase.updateStatus(self, s)
end

function ThreeRoundsScreen:closeScreen()
    self:_stopCountdown()
    ScreenBase.closeScreen(self)
end

return ThreeRoundsScreen
