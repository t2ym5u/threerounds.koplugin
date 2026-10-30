-- Text helpers and the score table for the Three Rounds screen.

local Device          = require("device")
local Font            = require("ui/font")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local LineWidget      = require("ui/widget/linewidget")
local Blitbuffer      = require("ffi/blitbuffer")
local Size            = require("ui/size")

local DeviceScreen = Device.screen

-- Font:getFace() scales by DPI: pixel-derived sizes are divided back first.
local DPI_SCALE = DeviceScreen:scaleBySize(1000) / 1000

local W = {}

function W.pxFace(px, bold)
    return Font:getFace(bold and "tfont" or "cfont", math.max(8, math.floor(px / DPI_SCALE)))
end

-- One line at up to px, shrunk until it fits max_w.
function W.fitLine(text, px, max_w, bold)
    local tw
    while true do
        tw = TextWidget:new{ text = text, face = W.pxFace(px, bold), bold = bold }
        if tw:getSize().w <= max_w or px <= 12 then break end
        tw:free()
        px = math.floor(px * 0.9)
    end
    if tw:getSize().w > max_w then
        tw:free()
        tw = TextWidget:new{ text = text, face = W.pxFace(px, bold), bold = bold, max_width = max_w }
    end
    return tw
end

-- A centred paragraph as big as possible (<= max_px) inside width x max_h,
-- without splitting a word across lines.
function W.fitParagraph(text, max_px, width, max_h, bold)
    local px = max_px
    while true do
        local face = W.pxFace(px, bold)
        local words_fit = true
        for word in text:gmatch("%S+") do
            local tw = TextWidget:new{ text = word, face = face, bold = bold }
            local w = tw:getSize().w
            tw:free()
            if w > width then words_fit = false; break end
        end
        if words_fit or px <= 12 then
            local tb = TextBoxWidget:new{ text = text, face = face, bold = bold, width = width,
                                          alignment = "center" }
            if tb:getSize().h <= max_h or px <= 12 then return tb end
            tb:free()
        end
        px = math.floor(px * 0.9)
    end
end

-- Score table: one row per team, one column per round played, then total.
-- rows: { { name, s1, s2, s3, total, bold } }, headers: { "", "1", "2", "3", "Total" }
function W.scoreTable(headers, rows, width, max_h)
    local n = #rows + 1
    local row_h = math.floor(math.min(max_h / n, width * 0.12))
    local px = math.max(14, math.floor(row_h * 0.45))
    local ncols = #headers - 1
    local name_w = math.floor(width * (ncols > 2 and 0.42 or 0.6))
    local col_w = math.floor((width - name_w) / ncols)
    local function row(cells, bold_last, bold_all)
        local hg = HorizontalGroup:new{
            align = "center",
            LeftContainer:new{ dimen = Geom:new{ w = name_w, h = row_h },
                W.fitLine(cells[1], px, name_w - Size.padding.default, true) },
        }
        for i = 2, #cells do
            local bold = bold_all or (bold_last and i == #cells)
            hg[#hg + 1] = CenterContainer:new{ dimen = Geom:new{ w = col_w, h = row_h },
                W.fitLine(tostring(cells[i]), px, col_w - Size.padding.small, bold) }
        end
        return hg
    end
    local g = VerticalGroup:new{ align = "left", row(headers, false, true),
        LineWidget:new{ background = Blitbuffer.COLOR_GRAY,
                        dimen = Geom:new{ w = width, h = Size.line.medium } } }
    for _, r in ipairs(rows) do g[#g + 1] = row(r, true) end
    return g
end

return W
