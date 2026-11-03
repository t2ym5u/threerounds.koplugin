-- busted specs for the Three Rounds game logic and card banks.
package.path = "./?.lua;./common/?.lua;" .. package.path
local Game = require("game")

local SeenHistory = require("seen_history")

local function bank(lang) return dofile("cards_" .. lang .. ".lua") end

-- Plugin settings stand-in, kept between "sessions".
local function fakePlugin()
    local store = {}
    return {
        store = store,
        getSetting  = function(_self, k, d) if store[k] == nil then return d end return store[k] end,
        saveSetting = function(_self, k, v) store[k] = v end,
    }
end

-- Deterministic rng for reproducible decks.
local function lcg(seed)
    local s = seed
    return function(n)
        s = (s * 1103515245 + 12345) % 2147483648
        return s % n + 1
    end
end

local EXCLUDED = { "hitler", "staline", "stalin", "pol pot", "ben laden", "bin laden", "mussolini",
                   "mao", "lénine", "lenin", "robespierre", "attila", "jack l'éventreur",
                   "jack the ripper", "al capone", "caligula", "néron", "nero", "franco",
                   "pinochet", "saddam", "kadhafi", "gaddafi", "idi amin", "ceausescu", "kim jong",
                   "ted bundy", "landru", "petiot", "dahmer", "genghis khan", "gengis khan",
                   "himmler", "goebbels", "mengele", "trotsky", "castro", "putin", "poutine" }

local function newGame(opts)
    opts = opts or {}
    opts.teams = opts.teams or { "Red", "Blue" }
    opts.rng = opts.rng or lcg(1)
    return Game.new(opts)
end

describe("card banks", function()
    for _, lang in ipairs({ "fr", "en" }) do
        it(lang .. " has at least 1500 distinct cards, every theme filled", function()
            local b = bank(lang)
            local n, seen = 0, {}
            local known = {}
            for _, t in ipairs(Game.THEMES) do known[t] = true end
            for theme, cards in pairs(b) do
                assert.is_true(known[theme], theme)
                assert.is_true(#cards >= 100, theme)
                for _, c in ipairs(cards) do
                    assert.is_string(c)
                    assert.is_true(#c <= 40, c)
                    assert.is_nil(seen[c:lower()], "duplicate: " .. c)
                    seen[c:lower()] = true
                    n = n + 1
                    local padded = " " .. c:lower():gsub("%p", " ") .. " "
                    for _, bad in ipairs(EXCLUDED) do
                        local word = " " .. bad:gsub("%p", " ") .. " "
                        assert.is_nil(padded:find(word, 1, true), "excluded name: " .. c)
                    end
                end
            end
            assert.is_true(n >= 1500, "only " .. n)
            for _, t in ipairs(Game.THEMES) do assert.is_table(b[t], t) end
        end)
    end
end)

describe("deck", function()
    it("leaves the kids' cards out by default", function()
        local deck = Game.pickDeck(bank("en"), nil, 60, nil, lcg(9))
        assert.are.equal(60, #deck)
        for _, c in ipairs(deck) do assert.are_not.equal("kids", c.theme) end
        local kids = Game.pickDeck(bank("en"), { kids = true }, 30, nil, lcg(9))
        for _, c in ipairs(kids) do assert.are.equal("kids", c.theme) end
    end)

    it("picks the requested size from the selected themes, preferring fresh cards", function()
        local b = bank("fr")
        local deck = Game.pickDeck(b, { history = true }, 30, nil, lcg(3))
        assert.are.equal(30, #deck)
        for _, c in ipairs(deck) do assert.are.equal("history", c.theme) end
        local p = fakePlugin()
        local seen = SeenHistory.open(p, "cards_fr")
        seen:mark(deck)
        local recent = {}
        for _, c in ipairs(deck) do recent[c.text] = true end
        local deck2 = Game.pickDeck(b, { history = true }, 30, seen, lcg(4))
        local reused = 0
        for _, c in ipairs(deck2) do if recent[c.text] then reused = reused + 1 end end
        -- the theme has more than 60 cards: 30 fresh ones exist, none is reused
        assert.is_true(#b.history >= 60)
        assert.are.equal(0, reused)
        local big = Game.pickDeck(b, { history = true }, 60, seen, lcg(5))
        assert.are.equal(60, #big)
    end)
end)

describe("deck history across sessions", function()
    it("never deals a card again until the selected themes are used up", function()
        local b = { history = {}, food = { "Crêpe" } }
        for i = 1, 25 do b.history[i] = "H" .. i end
        local p = fakePlugin()
        local got = {}
        for session = 1, 5 do
            local seen = SeenHistory.open(p, "cards_fr", { max = 3000 })   -- reopened each session
            local d = Game.pickDeck(b, { history = true }, 5, seen, lcg(session))
            assert.are.equal(5, #d)
            for _, c in ipairs(d) do
                assert.is_nil(got[c.text], "session " .. session .. " repeated " .. c.text)
                got[c.text] = true
            end
        end
        -- all 25 dealt: a 6th game starts a new cycle with a full deck
        local d = Game.pickDeck(b, { history = true }, 5, SeenHistory.open(p, "cards_fr"), lcg(7))
        assert.are.equal(5, #d)
    end)

    it("migrates the 1.0.x recent_cards list into each language once", function()
        local p = fakePlugin()
        local banks = { fr = { history = { "Napoléon", "Molière" } }, en = { history = { "Newton" } } }
        Game.migrateRecent({ "Newton", "Molière", "Gone", "Napoléon" }, banks,
            function(lang) return SeenHistory.open(p, "cards_" .. lang) end)
        assert.are.same({ "Napoléon", "Molière" }, p.store.seen_cards_fr)
        assert.are.same({ "Newton" }, p.store.seen_cards_en)
        local fr = { history = { "Napoléon", "Molière", "Curie" } }
        local d = Game.pickDeck(fr, { history = true }, 1, SeenHistory.open(p, "cards_fr"), lcg(1))
        assert.are.equal("Curie", d[1].text)
    end)
end)

local function deck(n)
    local d = {}
    for i = 1, n do d[i] = { text = "Card " .. i, theme = "history" } end
    return d
end

describe("a full game", function()
    it("plays three rounds with the same deck", function()
        local g = newGame()
        g:startGame(deck(5))
        assert.are.equal("handover", g.phase)
        assert.are.equal(1, g.round)
        assert.is_false(g:canPass())          -- round 1: no passing by default

        g:startTurn()
        assert.are.equal("turn", g.phase)
        assert.is_false(g:pass())
        g:found(); g:found()
        assert.are.equal(2, g.teams[1].scores[1])
        g:endTurn()
        assert.are.equal("handover", g.phase)
        assert.are.equal(2, g.current_team)
        assert.are.same({ team = 1, found = 2 }, g.last_turn)
        assert.are.equal(3, #g.pool)

        g:startTurn()
        g:found(); g:found()
        assert.is_true(g:found())             -- pool empty: round over
        assert.are.equal("round_end", g.phase)
        assert.are.equal(3, g.teams[2].scores[1])
        assert.are.equal(1, g.current_team)   -- next team starts round 2

        g:nextRound()
        assert.are.equal(2, g.round)
        assert.are.equal(5, #g.pool)          -- same deck, refilled
        g:startTurn()
        assert.is_true(g:canPass())
        local first = g:currentCard()
        assert.is_true(g:pass())
        assert.are_not.equal(first, g:currentCard())
        assert.are.equal(first, g.deck[g.pool[#g.pool]])   -- passed card at the bottom
        for _ = 1, 4 do g:found() end
        assert.is_false(g:isGameOver())
        assert.is_true(g:found())
        assert.are.equal("round_end", g.phase)
        assert.are.equal(5, g.teams[1].scores[2])

        g:nextRound()
        g:startTurn()
        for _ = 1, 5 do g:found() end
        assert.are.equal("game_over", g.phase)
        assert.is_true(g:isGameOver())
        assert.are.equal(2 + 5, g:total(1))
        assert.are.equal(3 + 5, g:total(2))
        assert.are.equal(2, g:winner())
        assert.are.same({ 2, 1 }, g:ranking())
    end)

    it("undoes found and pass within a turn", function()
        local g = newGame{ pass_rule = "all" }
        g:startGame(deck(4))
        g:startTurn()
        local a = g:currentCard()
        g:found()
        assert.are.equal(1, g.teams[1].scores[1])
        assert.is_true(g:undo())
        assert.are.equal(0, g.teams[1].scores[1])
        assert.are.equal(a, g:currentCard())
        assert.are.equal(4, #g.pool)
        g:pass()
        assert.are_not.equal(a, g:currentCard())
        g:undo()
        assert.are.equal(a, g:currentCard())
        assert.is_false(g:undo())
    end)

    it("never-pass rule and the last card can't be passed", function()
        local g = newGame{ pass_rule = "never" }
        g:startGame(deck(3)); g.round = 3
        g:startTurn()
        assert.is_false(g:canPass())
        local h = newGame{ pass_rule = "all" }
        h:startGame(deck(2)); h:startTurn(); h:found()
        assert.is_false(h:canPass())          -- one card left: nothing to pass to
    end)

    it("time's up puts the card in hand at the bottom", function()
        local g = newGame()
        g:startGame(deck(4))
        g:startTurn()
        local a = g:currentCard()
        g:endTurn()
        assert.are.equal(a, g.deck[g.pool[#g.pool]])
    end)

    it("reports a tie", function()
        local g = newGame()
        g:startGame(deck(2))
        g:startTurn(); g:found(); g:endTurn()
        g:startTurn(); g:found()
        assert.is_nil(g:winner())
    end)
end)

describe("save / restore", function()
    it("restores a turn in progress as a hand-over for the same team", function()
        local g = newGame{ teams = { "A", "B", "C" } }
        g:startGame(deck(6))
        g:startTurn(); g:endTurn()           -- team 2 now
        g:startTurn(); g:found()
        local s = g:serialize()
        local h = newGame()
        assert.is_true(h:load(s))
        assert.are.equal("handover", h.phase)
        assert.are.equal(2, h.current_team)
        assert.are.equal(3, #h.teams)
        assert.are.equal(1, h.teams[2].scores[1])
        assert.are.equal(5, #h.pool)
        assert.are.same(g.pool, h.pool)
    end)

    it("restores a finished game as over", function()
        local g = newGame()
        g:startGame(deck(1))
        for _ = 1, 3 do
            g:startTurn(); g:found()
            if g.phase == "round_end" then g:nextRound() end
        end
        assert.is_true(g:isGameOver())
        local h = newGame()
        h:load(g:serialize())
        assert.is_true(h:isGameOver())
    end)

    it("rejects garbage", function()
        local g = newGame()
        assert.is_false(g:load(nil))
        assert.is_false(g:load({ version = 1, teams = { { name = "x" } } }))
        assert.are.equal("setup", g.phase)
    end)
end)
