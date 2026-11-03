-- Three Rounds game logic: one deck, three rounds (describe / one word /
-- mime), teams taking timed turns until the pool is empty. Pure Lua, no UI.

local Game = {}
Game.__index = Game

Game.ROUNDS = 3
Game.THEMES = { "history", "science", "inventions", "arts", "music", "fiction", "screen",
                "places", "monuments", "sport", "myth", "food", "animals", "kids" }
-- Themes dealt when the players haven't picked any: everything but the
-- easy kids' cards, which would make an adult game too easy.
Game.DEFAULT_THEMES = {}
for _, t in ipairs(Game.THEMES) do Game.DEFAULT_THEMES[t] = t ~= "kids" or nil end

-- Pass rules: in which rounds the speaker may send a card back.
Game.PASS_RULES = {
    r23   = { false, true, true },
    all   = { true, true, true },
    never = { false, false, false },
}
Game.PASS_ORDER = { "r23", "all", "never" }

local function shuffle(t, rng)
    for i = #t, 2, -1 do
        local j = rng(i)
        t[i], t[j] = t[j], t[i]
    end
    return t
end

-- Draws `size` cards from bank ({ theme = { "name", ... } }) restricted to
-- `themes` (set, nil = the default themes). `seen` (a SeenHistory, ids =
-- card names) remembers the cards of earlier games: a card comes back only
-- once every card of the selected themes has been dealt. The deck is marked
-- as seen. Without `seen`, plain random.
function Game.pickDeck(bank, themes, size, seen, rng)
    rng = rng or math.random
    local pool = {}
    themes = themes or Game.DEFAULT_THEMES
    for _, theme in ipairs(Game.THEMES) do
        if bank[theme] and themes[theme] then
            for _, name in ipairs(bank[theme]) do
                pool[#pool + 1] = { text = name, theme = theme }
            end
        end
    end
    if seen then return seen:draw(pool, size, rng) end
    shuffle(pool, rng)
    local deck = {}
    for i = 1, math.min(size, #pool) do deck[i] = pool[i] end
    return deck
end

-- The 1.0.x "recent_cards" list (newest first, languages mixed) into the
-- per-language histories: banks = { fr = bank, en = bank }, seenFor(lang)
-- -> SeenHistory. Marked oldest first, so the history keeps their order.
function Game.migrateRecent(list, banks, seenFor)
    for lang, bank in pairs(banks) do
        local in_bank = {}
        for _, names in pairs(bank) do
            for _, n in ipairs(names) do in_bank[n] = true end
        end
        local items = {}
        for i = #list, 1, -1 do
            if in_bank[list[i]] then items[#items + 1] = list[i] end
        end
        if #items > 0 then seenFor(lang):mark(items) end
    end
end

-- opts: teams (list of names), pass_rule, rng
function Game.new(opts)
    local self = setmetatable({}, Game)
    self.rng = opts.rng or math.random
    self.pass_rule = Game.PASS_RULES[opts.pass_rule] and opts.pass_rule or "r23"
    self:newGame(opts.teams or { "Team 1", "Team 2" })
    return self
end

function Game:newGame(team_names)
    self.teams = {}
    for i, name in ipairs(team_names) do
        self.teams[i] = { name = name, scores = { 0, 0, 0 } }
    end
    self.phase        = "setup"   -- setup | handover | turn | round_end | game_over
    self.deck         = {}
    self.pool         = {}
    self.round        = 0
    self.current_team = 1
    self.actions      = {}
    self.last_turn    = nil       -- { team = i, found = n }
end

function Game:_refillPool()
    self.pool = {}
    for i = 1, #self.deck do self.pool[i] = i end
    shuffle(self.pool, self.rng)
end

function Game:startGame(deck)
    self.deck = deck
    self.round = 1
    self.current_team = 1
    self.last_turn = nil
    for _, t in ipairs(self.teams) do t.scores = { 0, 0, 0 } end
    self:_refillPool()
    self.phase = "handover"
end

function Game:canPass()
    local rule = Game.PASS_RULES[self.pass_rule]
    return rule[self.round] == true and #self.pool > 1
end

function Game:currentCard()
    local idx = self.pool[1]
    return idx and self.deck[idx]
end

function Game:startTurn()
    if self.phase ~= "handover" then return end
    self.actions = {}
    self.turn_found = 0
    self.phase = "turn"
end

function Game:_nextTeam()
    self.current_team = self.current_team % #self.teams + 1
end

function Game:_endRound()
    self.last_turn = { team = self.current_team, found = self.turn_found }
    self.actions = {}
    self:_nextTeam()
    self.phase = self.round >= Game.ROUNDS and "game_over" or "round_end"
end

-- The team guessed the card: +1, the card leaves the pool. Returns true when
-- that emptied the pool (the round is over).
function Game:found()
    if self.phase ~= "turn" or #self.pool == 0 then return false end
    local idx = table.remove(self.pool, 1)
    local team = self.teams[self.current_team]
    team.scores[self.round] = team.scores[self.round] + 1
    self.turn_found = self.turn_found + 1
    self.actions[#self.actions + 1] = { kind = "found", idx = idx }
    if #self.pool == 0 then
        self:_endRound()
        return true
    end
    return false
end

-- The card goes back to the bottom of the pool.
function Game:pass()
    if self.phase ~= "turn" or not self:canPass() then return false end
    local idx = table.remove(self.pool, 1)
    self.pool[#self.pool + 1] = idx
    self.actions[#self.actions + 1] = { kind = "pass", idx = idx }
    return true
end

function Game:canUndo()
    return self.phase == "turn" and #self.actions > 0
end

-- Takes back the last Found or Pass of this turn.
function Game:undo()
    if not self:canUndo() then return false end
    local a = table.remove(self.actions)
    if a.kind == "found" then
        table.insert(self.pool, 1, a.idx)
        local team = self.teams[self.current_team]
        team.scores[self.round] = team.scores[self.round] - 1
        self.turn_found = self.turn_found - 1
    else
        table.remove(self.pool)
        table.insert(self.pool, 1, a.idx)
    end
    return true
end

-- Time's up: the card in hand goes to the bottom, the next team plays.
function Game:endTurn()
    if self.phase ~= "turn" then return end
    if #self.pool > 1 then
        local idx = table.remove(self.pool, 1)
        self.pool[#self.pool + 1] = idx
    end
    self.last_turn = { team = self.current_team, found = self.turn_found }
    self.actions = {}
    self:_nextTeam()
    self.phase = "handover"
end

function Game:nextRound()
    if self.phase ~= "round_end" then return end
    self.round = self.round + 1
    self.last_turn = nil
    self:_refillPool()
    self.phase = "handover"
end

function Game:total(i)
    local s = self.teams[i].scores
    return s[1] + s[2] + s[3]
end

function Game:ranking()
    local idx = {}
    for i = 1, #self.teams do idx[i] = i end
    table.sort(idx, function(a, b)
        local ta, tb = self:total(a), self:total(b)
        if ta ~= tb then return ta > tb end
        return a < b
    end)
    return idx
end

-- Index of the winning team, or nil on a tie at the top.
function Game:winner()
    local r = self:ranking()
    if #r > 1 and self:total(r[1]) == self:total(r[2]) then return nil end
    return r[1]
end

function Game:isGameOver()
    return self.phase == "game_over"
end

-- ---------------------------------------------------------------------------
-- Save / restore. A turn cut short (reader closed) restarts as a hand-over
-- for the same team: its timer is gone, its points stay.
-- ---------------------------------------------------------------------------

function Game:serialize()
    local teams, deck, pool = {}, {}, {}
    for i, t in ipairs(self.teams) do
        teams[i] = { name = t.name, scores = { t.scores[1], t.scores[2], t.scores[3] } }
    end
    for i, c in ipairs(self.deck) do deck[i] = { text = c.text, theme = c.theme } end
    for i, v in ipairs(self.pool) do pool[i] = v end
    local phase = self.phase == "turn" and "handover" or self.phase
    return {
        version = 1, phase = phase, round = self.round, current_team = self.current_team,
        teams = teams, deck = deck, pool = pool, last_turn = self.last_turn,
    }
end

function Game:load(state)
    if type(state) ~= "table" or state.version ~= 1 or type(state.teams) ~= "table"
        or #state.teams < 2 then
        return false
    end
    self.teams = {}
    for i, t in ipairs(state.teams) do
        local s = t.scores or {}
        self.teams[i] = { name = tostring(t.name or i),
                          scores = { s[1] or 0, s[2] or 0, s[3] or 0 } }
    end
    self.deck = state.deck or {}
    self.pool = state.pool or {}
    self.round = state.round or 0
    self.current_team = math.max(1, math.min(#self.teams, state.current_team or 1))
    self.last_turn = state.last_turn
    self.actions = {}
    self.phase = state.phase or "setup"
    if self.phase == "turn" then self.phase = "handover" end
    if self.phase ~= "setup" and #self.deck == 0 then self.phase = "setup" end
    return true
end

return Game
