local Canvas = require('ui.canvas')
local class  = require('class')
local Event  = require('event')
local Tween  = require('ui.tween')
local Util   = require('util')

local _srep = string.rep
local _ssub = string.sub

local function safeValue(v)
  local t = type(v)
  if t == 'string' or t == 'number' then
    return v
  end
  return tostring(v)
end

-- need to add offsets to this test
local function getPosition(element)
  local x, y = 1, 1
  repeat
    x = element.x + x - 1
    y = element.y + y - 1
    element = element.parent
  until not element
  return x, y
end

local function assertElement(el, msg)
  if not el or not type(el) == 'table' or not el.UIElement then
    error(msg, 3)
  end
end

--[[-- Top Level Manager --]]--
local Manager = class()
function Manager:init(args)
  local control = false
  local shift = false
  local mouseDragged = false
  local pages = { }
  local running = false

  -- single thread all input events
  local function singleThread(event, fn)
    Event.on(event, function(...)
      if not running then
        running = true
        fn(...)
        running = false
      end
    end)
  end

  singleThread('term_resize', function(h, side)
    if self.currentPage then
      -- the parent doesn't have any children set...
      -- that's why we have to resize both the parent and the current page
      -- kinda makes sense
      if self.currentPage.parent.device.side == side then
        self.currentPage.parent:resize()

        self.currentPage:resize()
        self.currentPage:draw()
        self.currentPage:sync()
      end
    end
  end)

  singleThread('mouse_scroll', function(h, direction, x, y)
    if self.target then
      local event = self:pointToChild(self.target, x, y)
      local directions = {
        [ -1 ] = 'up',
        [  1 ] = 'down'
      }
      -- revisit - should send out scroll_up and scroll_down events
      -- let the element convert them to up / down
      self:inputEvent(event.element,
        { type = 'key', key = directions[direction] })
      self.currentPage:sync()
    end
  end)

  -- this should be moved to the device !
  singleThread('monitor_touch', function(h, side, x, y)
    if self.currentPage then
      if self.currentPage.parent.device.side == side then
        self:click(1, x, y)
      end
    end
  end)

  singleThread('mouse_click', function(h, button, x, y)

    mouseDragged = false
    if button == 1 and shift and control then -- debug hack
      local event = self:pointToChild(self.target, x, y)
      multishell.openTab({ path = 'sys/apps/Lua.lua', args = { event.element }, focused = true })

    elseif self.currentPage then
      if not self.currentPage.parent.device.side then
        local event = self:pointToChild(self.target, x, y)
        if event.element.focus then
          self.currentPage:setFocus(event.element)
          self.currentPage:sync()
        end
      end
    end
  end)

  singleThread('mouse_up', function(h, button, x, y)

    if self.currentPage and not mouseDragged then
      if not self.currentPage.parent.device.side then
        self:click(button, x, y)
      end
    end
  end)

  singleThread('mouse_drag', function(h, button, x, y)

    mouseDragged = true
    if self.target then
      local event = self:pointToChild(self.target, x, y)

      -- revisit - should send out scroll_up and scroll_down events
      -- let the element convert them to up / down
      self:inputEvent(event.element,
        { type = 'mouse_drag', button = button, x = event.x, y = event.y })
      self.currentPage:sync()
    end
  end)

  singleThread('paste', function(h, text)
    if clipboard.isInternal() then
      text = clipboard.getData()
    end
    if text and type(text) == 'string' then
      self:emitEvent({ type = 'paste', text = text })
      self.currentPage:sync()
    end
  end)

  singleThread('char', function(h, ch)
    control = false
    if self.currentPage then
      self:inputEvent(self.currentPage.focused, { type = 'key', key = ch })
      self.currentPage:sync()
    end
  end)

  singleThread('key_up', function(h, code)
    if code == keys.leftCtrl or code == keys.rightCtrl then
      control = false
    elseif code == keys.leftShift or code == keys.rightShift then
      shift = false
    end
  end)

  singleThread('key', function(h, code)
    local ch = keys.getName(code)
    if not ch then
      return
    end

    if code == keys.leftCtrl or code == keys.rightCtrl then
      control = true
    elseif code == keys.leftShift or code == keys.rightShift  then
      shift = true
    elseif control then
      ch = 'control-' .. ch
    elseif shift and ch == 'tab' then
      ch = 'shiftTab'
    end

    -- filter out a through z and numbers as they will be get picked up
    -- as char events
    if ch and #ch > 1 and (code < 2 or code > 11) then
      if self.currentPage then
        self:inputEvent(self.currentPage.focused,
          { type = 'key', key = ch, element = self.currentPage.focused })
        self.currentPage:sync()
      end
    end
  end)
end

function Manager:configure(appName, ...)
  local options = {
    device     = { arg = 'd', type = 'string',
                   desc = 'Device type' },
    textScale  = { arg = 't', type = 'number',
                   desc = 'Text scale' },
  }
  local defaults = Util.loadTable('usr/config/' .. appName) or { }
  if not defaults.device then
    defaults.device = { }
  end

  Util.getOptions(options, { ... }, true)
  local optionValues = {
    name = options.device.value,
    textScale = options.textScale.value,
  }

  Util.merge(defaults.device, optionValues)

  if defaults.device.name then

    local dev

    if defaults.device.name == 'terminal' then
      dev = term.current()
    else
      dev = device[defaults.device.name]
    end

    if not dev then
      error('Invalid display device')
    end
    local device = self.Device({
      device = dev,
      textScale = defaults.device.textScale,
    })
    self:setDefaultDevice(device)
  end

  if defaults.theme then
    for k,v in pairs(defaults.theme) do
      if self[k] and self[k].defaults then
        Util.merge(self[k].defaults, v)
      end
    end
  end
end

function Manager:disableEffects()
  self.defaultDevice.effectsEnabled = false
end

function Manager:loadTheme(filename)
  if fs.exists(filename) then
    local theme, err = Util.loadTable(filename)
    if not theme then
      error(err)
    end
    for k,v in pairs(theme) do
      if self[k] and self[k].defaults then
        Util.merge(self[k].defaults, v)
      end
    end
  end
end

function Manager:emitEvent(event)
  if self.currentPage and self.currentPage.focused then
    return self.currentPage.focused:emit(event)
  end
end

function Manager:inputEvent(parent, event)

  while parent do
    local acc =  parent.accelerators[event.key]
    if acc then
      if parent:emit({ type = acc, element = parent }) then
        return true
      end
    end
    if parent.eventHandler then
      if parent:eventHandler(event) then
        return true
      end
    end
    parent = parent.parent
  end
end

function Manager:pointToChild(parent, x, y)
  x = x + parent.offx - parent.x + 1
  y = y + parent.offy - parent.y + 1
  if parent.children then
    for _,child in pairs(parent.children) do
      if child.enabled and 
         x >= child.x and x < child.x + child.width and
         y >= child.y and y < child.y + child.height then
        local c = self:pointToChild(child, x, y)
        if c then
          return c
        end
      end
    end
  end
  return {
    element = parent,
    x = x,
    y = y
  }
end

function Manager:click(button, x, y)
  if self.target then

    local target = self.target

    -- need to add offsets into this check
    if x < self.target.x or y < self.target.y or
      x > self.target.x + self.target.width - 1 or
      y > self.target.y + self.target.height - 1 then
      target:emit({ type = 'mouse_out' })

      target = self.currentPage
    end

    local clickEvent = self:pointToChild(target, x, y)

    if button == 1 then
      local c = os.clock()

      --if self.doubleClickTimer then
      --  debug(c - self.doubleClickTimer)
      --end

      if self.doubleClickTimer and (c - self.doubleClickTimer < 1.9) and
         self.doubleClickX == x and self.doubleClickY == y and
         self.doubleClickElement == clickEvent.element then
        button = 3
        self.doubleClickTimer = nil
      else
        self.doubleClickTimer = c
        self.doubleClickX = x
        self.doubleClickY = y
        self.doubleClickElement = clickEvent.element
      end
    else
      self.doubleClickTimer = nil
    end

    local events = { 'mouse_click', 'mouse_rightclick', 'mouse_doubleclick' }

    clickEvent.button = button
    clickEvent.type = events[button]
    clickEvent.key = events[button]

    if clickEvent.element.focus then
      self.currentPage:setFocus(clickEvent.element)
    end
    if not self:inputEvent(clickEvent.element, clickEvent) then
      if button == 3 then
        -- if the double-click was not captured
        -- send through a single-click
        clickEvent.button = 1
        clickEvent.type = events[1]
        clickEvent.key = events[1]
        self:inputEvent(clickEvent.element, clickEvent)
      end
    end

    self.currentPage:sync()
  end
end

function Manager:setDefaultDevice(device)
  self.defaultDevice = device
  self.term = device
end

function Manager:addPage(name, page)
  self.pages[name] = page
end

function Manager:setPages(pages)
  self.pages = pages
end

function Manager:getPage(pageName)
  local page = self.pages[pageName]

  if not page then
    error('UI:getPage: Invalid page: ' .. tostring(pageName), 2)
  end

  return page
end

function Manager:setPage(pageOrName, ...)
  local page = pageOrName

  if type(pageOrName) == 'string' then
    page = self.pages[pageOrName]
  end

  if page == self.currentPage then
    page:draw()
  else
    local needSync
    if self.currentPage then
      if self.currentPage.focused then
        self.currentPage.focused.focused = false
        self.currentPage.focused:focus()
      end
      self.currentPage:disable()
      page.previousPage = self.currentPage
    else
      needSync = true
    end
    self.currentPage = page
    self.currentPage:clear(page.backgroundColor)
    page:enable(...)
    page:draw()
    if self.currentPage.focused then
      self.currentPage.focused.focused = true
      self.currentPage.focused:focus()
    end
    self:capture(self.currentPage)
    if needSync then
      page:sync() -- first time a page has been set
    end
  end
end

function Manager:getCurrentPage()
  return self.currentPage
end

function Manager:setPreviousPage()
  if self.currentPage.previousPage then
    local previousPage = self.currentPage.previousPage.previousPage
    self:setPage(self.currentPage.previousPage)
    self.currentPage.previousPage = previousPage
  end
end

function Manager:capture(child)
  self.target = child
end

function Manager:release(child)
  if self.target == child then
    self.target = self.currentPage
  end
end

function Manager:getDefaults(element, args)
  local defaults = Util.deepCopy(element.defaults)
  if args then
    Manager:setProperties(defaults, args)
  end
  return defaults
end

function Manager:pullEvents(...)
  Event.pullEvents(...)
  self.term:reset()
end

function Manager:exitPullEvents()
  Event.exitPullEvents()
end

function Manager:setProperties(obj, args)
  if args then
    for k,v in pairs(args) do
      if k == 'accelerators' then
        if obj.accelerators then
          Util.merge(obj.accelerators, args.accelerators)
        else
          obj[k] = v
        end
      else
        obj[k] = v
      end
    end
  end
end

local UI = Manager()

--[[-- Basic drawable area --]]--
UI.Window = class()
UI.Window.defaults = {
  UIElement = 'Window',
  x = 1,
  y = 1,
  -- z = 0, -- eventually...
  offx = 0,
  offy = 0,
  cursorX = 1,
  cursorY = 1,
  accelerators = { },
}
function UI.Window:init(args)
  local defaults = UI:getDefaults(UI.Window, args)
  UI:setProperties(self, defaults)

  if self.parent then
    self:setParent()
  end
end

function UI.Window:initChildren()
  local children = self.children

  -- insert any UI elements created using the shorthand
  -- window definition into the children array
  for k,child in pairs(self) do
    if k ~= 'parent' then -- reserved
      if type(child) == 'table' and child.UIElement and not child.parent then
        if not children then
          children = { }
        end
        table.insert(children, child)
      end
    end
  end
  if children then
    for _,child in pairs(children) do
      if not child.parent then
        child.parent = self
        child:setParent()
        -- child:reposition() -- maybe
        if self.enabled then
          child:enable()
        end
      end
    end
    self.children = children
  end
end

local function setSize(self)
  if self.x < 0 then
    self.x = self.parent.width + self.x + 1
  end
  if self.y < 0 then
    self.y = self.parent.height + self.y + 1
  end

  if self.ex then
    local ex = self.ex
    if self.ex <= 1 then
      ex = self.parent.width + self.ex + 1
    end
    if self.width then
      self.x = ex - self.width + 1
    else
      self.width = ex - self.x + 1
    end
  end
  if self.ey then
    local ey = self.ey
    if self.ey <= 1 then
      ey = self.parent.height + self.ey + 1
    end
    if self.height then
      self.y = ey - self.height + 1
    else
      self.height = ey - self.y + 1
    end
  end

  if not self.width then
    self.width = self.parent.width - self.x + 1
  end
  if not self.height then
    self.height = self.parent.height - self.y + 1
  end
end

-- bad name... should be called something like postInit
-- normally used to determine sizes since the parent is
-- only known at this point
function UI.Window:setParent()
  self.oh, self.ow = self.height, self.width
  self.ox, self.oy = self.x, self.y

  setSize(self)

  self:initChildren()
end

function UI.Window:resize()
  self.height, self.width = self.oh, self.ow
  self.x, self.y = self.ox, self.oy

  setSize(self)

  if self.children then
    for _,child in ipairs(self.children) do
      child:resize()
    end
  end
end

function UI.Window:add(children)
  UI:setProperties(self, children)
  self:initChildren()
end

function UI.Window:getCursorPos()
  return self.cursorX, self.cursorY
end

function UI.Window:setCursorPos(x, y)
  self.cursorX = x
  self.cursorY = y
  self.parent:setCursorPos(self.x + x - 1, self.y + y - 1)
end

function UI.Window:setCursorBlink(blink)
  self.parent:setCursorBlink(blink)
end

function UI.Window:draw()
  self:clear(self.backgroundColor)
  if self.children then
    for _,child in pairs(self.children) do
      if child.enabled then
        child:draw()
      end
    end
  end
end

function UI.Window:sync()
  if self.parent then
    self.parent:sync()
  end
end

function UI.Window:enable()
  self.enabled = true
  if self.children then
    for _,child in pairs(self.children) do
      child:enable()
    end
  end
end

function UI.Window:disable()
  self.enabled = false
  if self.children then
    for _,child in pairs(self.children) do
      child:disable()
    end
  end
end

function UI.Window:setTextScale(textScale)
  self.textScale = textScale
  self.parent:setTextScale(textScale)
end

function UI.Window:clear(bg)
  self:clearArea(1 + self.offx, 1 + self.offy, self.width, self.height, bg)
end

function UI.Window:clearLine(y, bg)
  self:write(1, y, _srep(' ', self.width), bg)
end

function UI.Window:clearArea(x, y, width, height, bg)
  if width > 0 then
    local filler = _srep(' ', width)
    for i = 0, height - 1 do
      self:write(x, y + i, filler, bg)
    end
  end
end

function UI.Window:write(x, y, text, bg, tc)
  bg = bg or self.backgroundColor
  tc = tc or self.textColor
  x = x - self.offx
  y = y - self.offy
  if y <= self.height and y > 0 then
    if self.canvas then
      self.canvas:write(x, y, text, bg, tc)
    else
      self.parent:write(
        self.x + x - 1, self.y + y - 1, tostring(text), bg, tc)
    end
  end
end

function UI.Window:centeredWrite(y, text, bg, fg)
  if #text >= self.width then
    self:write(1, y, text, bg)
  else
    local space = math.floor((self.width-#text) / 2)
    local filler = _srep(' ', space + 1)
    local str = _ssub(filler, 1, space) .. text
    str = str .. _ssub(filler, self.width - #str + 1)
    self:write(1, y, str, bg, fg)
  end
end

function UI.Window:print(text, bg, fg, indent)
  indent = indent or 1

  local function nextWord(line, cx)
    local result = { line:find("(%w+)", cx) }
    if #result > 1 and result[2] > cx then
      return _ssub(line, cx, result[2] + 1)
    elseif #result > 0 and result[1] == cx then
      result = { line:find("(%w+)", result[2] + 1) }
      if #result > 0 then
        return _ssub(line, cx, result[1] + 1)
      end
    end
    if cx <= #line then
      return _ssub(line, cx, #line)
    end
  end

  local function pieces(f, bg, fg)
    local pos = 1
    local t = { }
    while true do
      local s = f:find('\027', pos)
      if not s then
        break
      end
      if pos < s then
        table.insert(t, _ssub(f, pos, s - 1))
      end
      local seq = _ssub(f, s)
      seq = seq:match("\027%[([%d;]+)m")
      local e = { }
      for color in string.gmatch(seq, "%d+") do
        color = tonumber(color)
        if color == 0 then
          e.fg = fg
          e.bg = bg
        elseif color > 20 then
          e.bg = 2 ^ (color - 21)
        else
          e.fg = 2 ^ (color - 1)
        end
      end
      table.insert(t, e)
      pos = s + #seq + 3
    end
    if pos < #f then
      table.insert(t, _ssub(f, pos))
    end
    return t
  end

  local lines = Util.split(text)
  for k,line in pairs(lines) do
    local fragments = pieces(line, bg, fg)
    for l, fragment in ipairs(fragments) do
      local lx = 1
      if type(fragment) == 'table' then -- ansi sequence
        fg = fragment.fg
        bg = fragment.bg
      else
        while true do
          local word = nextWord(fragment, lx)
          if not word then
            break
          end
          local w = word
          if self.cursorX + #word > self.width then
            self.cursorX = indent
            self.cursorY = self.cursorY + 1
            w = word:gsub(' ', '')
          end
          self:write(self.cursorX, self.cursorY, w, bg, fg)
          self.cursorX = self.cursorX + #word
          lx = lx + #word
        end
      end
    end
    if lines[k + 1] then
      self.cursorX = indent
      self.cursorY = self.cursorY + 1
    end
  end

  return self.cursorX, self.cursorY
end

function UI.Window:setFocus(focus)
  assertElement(focus, 'UI.Window:setFocus: Invalid element passed')
  if self.parent then
    self.parent:setFocus(focus)
  end
end

function UI.Window:getFocusables()
  local focusable = { }

  local function focusSort(a, b)
    if a.y == b.y then
      return a.x < b.x
    end
    return a.y < b.y
  end

  local function getFocusable(parent, x, y)
    for _,child in Util.spairs(parent.children, focusSort) do
      if child.enabled and child.focus then
        table.insert(focusable, child)
      end
      if child.children then
        getFocusable(child, child.x + x, child.y + y)
      end
    end
  end

  if self.children then
    getFocusable(self, self.x, self.y)
  end

  return focusable
end

function UI.Window:focusFirst()

  local focusables = self:getFocusables()
  local focused = focusables[1]
  if focused then
    self:setFocus(focused)
  end
end

function UI.Window:scrollIntoView()
  local parent = self.parent

  if self.x <= parent.offx then
    parent.offx = math.max(0, self.x - 1)
    parent:draw()
  elseif self.x + self.width > parent.width + parent.offx then
    parent.offx = self.x + self.width - parent.width - 1
    parent:draw()
  end

  if self.y <= parent.offy then
    parent.offy = math.max(0, self.y - 1)
    parent:draw()
  elseif self.y + self.height > parent.height + parent.offy then
    parent.offy = self.y + self.height - parent.height - 1
    parent:draw()
  end
end

function UI.Window:addTransition(effect, args)
  if self.parent then
    args = args or { }
    if not args.x then -- not good
      args.x, args.y = getPosition(self)
      args.width = self.width
      args.height = self.height
    end

    args.canvas = args.canvas or self.canvas
    self.parent:addTransition(effect, args)
  end
end

function UI.Window:emit(event)
  local parent = self
  while parent do
    if parent.eventHandler then
      if parent:eventHandler(event) then
        return true
      end
    end
    parent = parent.parent
  end
end

function UI.Window:eventHandler(event)
  return false
end

--[[-- TransitionSlideLeft --]]--
UI.TransitionSlideLeft = class()
UI.TransitionSlideLeft.defaults = {
  UIElement = 'TransitionSlideLeft',
  ticks = 6,
  easing = 'outQuint',
}
function UI.TransitionSlideLeft:init(args)
  local defaults = UI:getDefaults(UI.TransitionSlideLeft, args)
  UI:setProperties(self, defaults)

  self.pos = { x = self.ex }
  self.tween = Tween.new(self.ticks, self.pos, { x = self.x }, self.easing)
  self.lastx = 0
  self.lastScreen = self.canvas:copy()
end

function UI.TransitionSlideLeft:update(device)
  self.tween:update(1)
  local x = math.floor(self.pos.x)
  if x ~= self.lastx then
    self.lastx = x
    self.lastScreen:dirty()
    self.lastScreen:blit(device, {
      x = self.ex - x + self.x,
      y = self.y,
      ex = self.ex,
      ey = self.ey },
      { x = self.x, y = self.y })

    self.canvas:blit(device, {
      x = self.x,
      y = self.y,
      ex = self.ex - x + self.x,
      ey = self.ey },
      { x = x, y = self.y })
  end
  return self.pos.x ~= self.x
end

--[[-- TransitionSlideRight --]]--
UI.TransitionSlideRight = class()
UI.TransitionSlideRight.defaults = {
  UIElement = 'TransitionSlideRight',
  ticks = 6,
  easing = 'outQuint',
}
function UI.TransitionSlideRight:init(args)
  local defaults = UI:getDefaults(UI.TransitionSlideRight, args)
  UI:setProperties(self, defaults)

  self.pos = { x = self.x }
  self.tween = Tween.new(self.ticks, self.pos, { x = self.ex }, self.easing)
  self.lastx = 0
  self.lastScreen = self.canvas:copy()
end

function UI.TransitionSlideRight:update(device)
  self.tween:update(1)
  local x = math.floor(self.pos.x)
  if x ~= self.lastx then
    self.lastx = x
    self.lastScreen:dirty()
    self.lastScreen:blit(device, {
      x = self.x,
      y = self.y,
      ex = self.ex - x + self.x,
      ey = self.ey },
      { x = x, y = self.y })
    self.canvas:blit(device, {
      x = self.ex - x + self.x,
      y = self.y,
      ex = self.ex,
      ey = self.ey },
      { x = self.x, y = self.y })
  end
  return self.pos.x ~= self.ex
end

--[[-- TransitionExpandUp --]]--
UI.TransitionExpandUp = class()
UI.TransitionExpandUp.defaults = {
  UIElement = 'TransitionExpandUp',
  ticks = 3,
  easing = 'linear',
}
function UI.TransitionExpandUp:init(args)
  local defaults = UI:getDefaults(UI.TransitionExpandUp, args)
  UI:setProperties(self, defaults)
  self.pos = { y = self.ey + 1 }
  self.tween = Tween.new(self.ticks, self.pos, { y = self.y }, self.easing)
end

function UI.TransitionExpandUp:update(device)
  self.tween:update(1)
  self.canvas:blit(device, nil, { x = self.x, y = math.floor(self.pos.y) })
  return self.pos.y ~= self.y
end

--[[-- TransitionGrow --]]--
UI.TransitionGrow = class()
UI.TransitionGrow.defaults = {
  UIElement = 'TransitionGrow',
  ticks = 3,
  easing = 'linear',
}
function UI.TransitionGrow:init(args)
  local defaults = UI:getDefaults(UI.TransitionGrow, args)
  UI:setProperties(self, defaults)
  self.tween = Tween.new(self.ticks,
    { x = self.width / 2 - 1, y = self.height / 2 - 1, w = 1, h = 1 },
    { x = 1, y = 1, w = self.width, h = self.height }, self.easing)
end

function UI.TransitionGrow:update(device)
  local finished = self.tween:update(1)
  local subj = self.tween.subject
  local rect = { x = math.floor(subj.x), y = math.floor(subj.y) }
  rect.ex = math.floor(rect.x + subj.w - 1)
  rect.ey = math.floor(rect.y + subj.h - 1)
  self.canvas:blit(device, rect, { x = self.x + rect.x - 1, y = self.y + rect.y - 1})
  return not finished
end

--[[-- Terminal for computer / advanced computer / monitor --]]--
UI.Device = class(UI.Window)
UI.Device.defaults = {
  UIElement = 'Device',
  backgroundColor = colors.black,
  textColor = colors.white,
  textScale = 1,
  effectsEnabled = true,
}
function UI.Device:init(args)
  local defaults = UI:getDefaults(UI.Device)
  defaults.device = term.current()
  UI:setProperties(defaults, args)

  if defaults.deviceType then
    defaults.device = device[defaults.deviceType]
  end

  if not defaults.device.setTextScale then
    defaults.device.setTextScale = function(...) end
  end

  defaults.device.setTextScale(defaults.textScale)
  defaults.width, defaults.height = defaults.device.getSize()

  UI.Window.init(self, defaults)

  self.isColor = self.device.isColor()

  self.canvas = Canvas({
    x = 1, y = 1, ex = self.width, ey = self.height,
    isColor = self.isColor,
  })
  self.canvas:clear(self.backgroundColor, self.textColor)
end

function UI.Device:resize()
  self.width, self.height = self.device.getSize()
  self.lines = { }
  self.canvas:resize(self.width, self.height)
  self.canvas:clear(self.backgroundColor, self.textColor)
  --UI.Window.resize(self)
end

function UI.Device:setCursorPos(x, y)
  self.cursorX = x
  self.cursorY = y
end

function UI.Device:getCursorBlink()
  return self.cursorBlink
end

function UI.Device:setCursorBlink(blink)
  self.cursorBlink = blink
  self.device.setCursorBlink(blink)
end

function UI.Device:setTextScale(textScale)
  self.textScale = textScale
  self.device.setTextScale(self.textScale)
end

function UI.Device:reset()
  self.device.setBackgroundColor(colors.black)
  self.device.setTextColor(colors.white)
  self.device.clear()
  self.device.setCursorPos(1, 1)
end

-- refactor into canvas...
function UI.Device:addTransition(effect, args)
  if not self.transitions then
    self.transitions = { }
  end

  args = args or { }
  args.ex = args.x + args.width - 1
  args.ey = args.y + args.height - 1
  args.canvas = args.canvas or self.canvas

  if type(effect) == 'string' then
    local transitions = {
      slideLeft  = UI.TransitionSlideLeft,
      slideRight = UI.TransitionSlideRight,
      expandUp   = UI.TransitionExpandUp,
      grow       = UI.TransitionGrow,
    }
    local c = transitions[effect]
    if not c then
      error('Invalid transition: ' .. effect)
    end
    effect = c(args)
  else
    Util.merge(effect, args)
  end

  table.insert(self.transitions, effect)
end

function UI.Device:runTransitions(transitions, canvas)

  for _,t in ipairs(transitions) do
    canvas:punch(t)               -- punch out the effect areas
  end
  canvas:blitClipped(self.device) -- and blit the remainder
  canvas:reset()

  while true do
    for _,k in ipairs(Util.keys(transitions)) do
      local transition = transitions[k]
      if not transition:update(self.device) then
        transitions[k] = nil
      end
    end
    if Util.empty(transitions) then
      break
    end
    os.sleep(0)
  end
end

function UI.Device:sync()

  local transitions
  if self.transitions and self.effectsEnabled then
    transitions = self.transitions
    self.transitions = nil
  end

  if self:getCursorBlink() then
    self.device.setCursorBlink(false)
  end

  if transitions then
    self:runTransitions(transitions, self.canvas)
  else
    self.canvas:render(self.device)
  end

  if self:getCursorBlink() then
    self.device.setCursorPos(self.cursorX, self.cursorY)
    self.device.setCursorBlink(true)
  end
end

--[[-- StringBuffer --]]--
-- justs optimizes string concatenations
UI.StringBuffer = class()
function UI.StringBuffer:init(bufSize)
  self.bufSize = bufSize
  self.buffer = {}
end

function UI.StringBuffer:insert(s, width)
  local len = #tostring(s or '')
  if len > width then
    s = _ssub(s, 1, width)
  end
  table.insert(self.buffer, s)
  if len < width then
    table.insert(self.buffer, _srep(' ', width - len))
  end
end

function UI.StringBuffer:get(sep)
  return Util.widthify(table.concat(self.buffer, sep or ''), self.bufSize)
end

function UI.StringBuffer:clear()
  self.buffer = { }
end

-- For manipulating text in a fixed width string
local SB = { }
function SB:new(width)
  return setmetatable({
    width = width,
    buf = _srep(' ', width)
  }, { __index = SB })
end
function SB:insert(x, str, width)
  if x < 1 then
    x = self.width + x + 1
  end
  width = width or #str
  if x + width - 1 > self.width then
    width = self.width - x
  end
  if width > 0 then
    self.buf = _ssub(self.buf, 1, x - 1) .. _ssub(str, 1, width) .. _ssub(self.buf, x + width)
  end
end
function SB:fill(x, ch, width)
  width = width or self.width - x + 1
  self:insert(x, _srep(ch, width))
end
function SB:center(str)
  self:insert(math.max(1, math.ceil((self.width - #str + 1) / 2)), str)
end
function SB:get()
  return self.buf
end

--[[-- Page (focus manager) --]]--
UI.Page = class(UI.Window)
UI.Page.defaults = {
  UIElement = 'Page',
  accelerators = {
    down = 'focus_next',
    enter = 'focus_next',
    tab = 'focus_next',
    shiftTab = 'focus_prev',
    up = 'focus_prev',
  },
  backgroundColor = colors.cyan,
  textColor = colors.white,
}
function UI.Page:init(args)
  local defaults = UI:getDefaults(UI.Page)
  defaults.parent = UI.defaultDevice
  UI:setProperties(defaults, args)
  UI.Window.init(self, defaults)

  if self.z then
    self.canvas = self.parent.canvas:addLayer(self, self.backgroundColor, self.textColor)
  else
    self.canvas = self.parent.canvas
  end
end

function UI.Page:enable()
  self.canvas.visible = true
  UI.Window.enable(self)

  if not self.focused or not self.focused.enabled then
    self:focusFirst()
  end
end

function UI.Page:disable()
  if self.z then
    self.canvas.visible = false
  end
end

function UI.Page:getFocused()
  return self.focused
end

function UI.Page:focusPrevious()

  local function getPreviousFocus(focused)
    local focusables = self:getFocusables()
    for k, v in ipairs(focusables) do
      if v == focused then
        if k > 1 then
          return focusables[k - 1]
        end
        return focusables[#focusables]
      end
    end
  end

  local focused = getPreviousFocus(self.focused)
  if focused then
    self:setFocus(focused)
  end
end

function UI.Page:focusNext()

  local function getNextFocus(focused)
    local focusables = self:getFocusables()
    for k, v in ipairs(focusables) do
      if v == focused then
        if k < #focusables then
          return focusables[k + 1]
        end
        return focusables[1]
      end
    end
  end

  local focused = getNextFocus(self.focused)
  if focused then
    self:setFocus(focused)
  end
end

function UI.Page:setFocus(child)
  assertElement(child, 'UI.Page:setFocus: Invalid element passed')

  if not child.focus then
    return
  end

  if self.focused and self.focused ~= child then
    self.focused.focused = false
    self.focused:focus()
    self.focused:emit({ type = 'focus_lost', focused = child })
  end

  self.focused = child
  if not child.focused then
    child.focused = true
    self:emit({ type = 'focus_change', focused = child })
  end

  child:focus()
end

function UI.Page:eventHandler(event)
  if self.focused then
    if event.type == 'focus_next' then
      self:focusNext()
      return true
    elseif event.type == 'focus_prev' then
      self:focusPrevious()
      return true
    end
  end
  return false
end

--[[-- Grid --]]--
UI.Grid = class(UI.Window)
UI.Grid.defaults = {
  UIElement = 'Grid',
  index = 1,
  inverseSort = false,
  disableHeader = false,
  selectable = true,
  textColor = colors.white,
  textSelectedColor = colors.white,
  backgroundColor = colors.black,
  backgroundSelectedColor = colors.gray,
  headerBackgroundColor = colors.cyan,
  headerTextColor = colors.white,
  unfocusedTextSelectedColor = colors.white,
  unfocusedBackgroundSelectedColor = colors.gray,
  focusIndicator = '>',
  sortIndicator = ' ',
  inverseSortIndicator = '^',
  values = { },
  columns = { },
  accelerators = {
    enter           = 'key_enter',
    [ 'control-c' ] = 'copy',
    down            = 'scroll_down',
    up              = 'scroll_up',
    home            = 'scroll_top',
    [ 'end' ]       = 'scroll_bottom',
    pageUp          = 'scroll_pageUp',
    [ 'control-b' ] = 'scroll_pageUp',
    pageDown        = 'scroll_pageDown',
    [ 'control-f' ] = 'scroll_pageDown',
  },
}
function UI.Grid:init(args)
  local defaults = UI:getDefaults(UI.Grid, args)
  UI.Window.init(self, defaults)

  for _,c in pairs(self.columns) do
    c.cw = c.width
    if not c.heading then
      c.heading = ''
    end
  end
end

function UI.Grid:setParent()
  UI.Window.setParent(self)
  self:update()

  if not self.pageSize then
    if self.disableHeader then
      self.pageSize = self.height
    else
      self.pageSize = self.height - 1
    end
  end
end

function UI.Grid:resize()
  UI.Window.resize(self)

  if self.disableHeader then
    self.pageSize = self.height
  else
    self.pageSize = self.height - 1
  end
  self:adjustWidth()
end

function UI.Grid:adjustWidth()

  local t = { }        -- cols without width
  local w = self.width - #self.columns - 1 -- width remaing

  for _,c in pairs(self.columns) do
    if c.width then
      c.cw = c.width
      w = w - c.cw
    else
      table.insert(t, c)
    end
  end

  if #t == 0 then
    return
  end

  if #t == 1 then
    t[1].cw = #(t[1].heading or '')
    t[1].cw = math.max(t[1].cw, w)
    return
  end

  if not self.autospace then
    for k,c in ipairs(t) do
      c.cw = math.floor(w / (#t - k + 1))
      w = w - c.cw
    end

  else
    for k,c in ipairs(t) do
      c.cw = #(c.heading or '')
      w = w - c.cw
    end
    -- adjust the size to the length of the value
    for key,row in pairs(self.values) do
      if w <= 0 then
        break
      end
      row = self:getDisplayValues(row, key)
      for _,col in pairs(t) do
        local value = row[col.key]
        if value then
          value = tostring(value)
          if #value > col.cw then
            w = w + col.cw
            col.cw = math.min(#value, w)
            w = w - col.cw
            if w <= 0 then
              break
            end
          end
        end
      end
    end

    -- last column does not get padding (right alignment)
    if not self.columns[#self.columns].width then
      Util.removeByValue(t, self.columns[#self.columns])
    end

    -- got some extra room - add some padding
    if w > 0 then
      for k,c in ipairs(t) do
        local padding = math.floor(w / (#t - k + 1))
        c.cw = c.cw + padding
        w = w - padding
      end
    end
  end
end

function UI.Grid:setPageSize(pageSize)
  self.pageSize = pageSize
end

function UI.Grid:getValues()
  return self.values
end

function UI.Grid:setValues(t)
  self.values = t
  self:update()
end

function UI.Grid:setInverseSort(inverseSort)
  self.inverseSort = inverseSort
  self:update()
  self:setIndex(self.index)
end

function UI.Grid:setSortColumn(column)
  self.sortColumn = column
end

function UI.Grid:getDisplayValues(row, key)
  return row
end

function UI.Grid:getSelected()
  if self.sorted then
    return self.values[self.sorted[self.index]], self.sorted[self.index]
  end
end

function UI.Grid:focus()
  self:drawRows()
end

function UI.Grid:draw()
  if not self.disableHeader then
    self:drawHeadings()
  end

  if self.index <= 0 then
    self:setIndex(1)
  elseif self.index > #self.sorted then
    self:setIndex(#self.sorted)
  end
  self:drawRows()
end

-- Something about the displayed table has changed
-- resort the table
function UI.Grid:update()

  local function sort(a, b)
    if not a[self.sortColumn] then
      return false
    elseif not b[self.sortColumn] then
      return true
    end
    return self:sortCompare(a, b)
  end

  local function inverseSort(a, b)
    return not sort(a, b)
  end

  local order
  if self.sortColumn then
    order = sort
    if self.inverseSort then
      order = inverseSort
    end
  end

  self.sorted = Util.keys(self.values)
  if order then
    table.sort(self.sorted, function(a,b)
      return order(self.values[a], self.values[b])
    end)
  end

  self:adjustWidth()
end

function UI.Grid:drawHeadings()
  local sb = UI.StringBuffer(self.width)
  for _,col in ipairs(self.columns) do
    local ind = ' '
    if col.key == self.sortColumn then
      if self.inverseSort then
        ind = self.inverseSortIndicator
      else
        ind = self.sortIndicator
      end
    end
    sb:insert(ind .. col.heading, col.cw + 1)
  end
  self:write(1, 1, sb:get(), self.headerBackgroundColor, self.headerTextColor)
end

function UI.Grid:sortCompare(a, b)
  local a = safeValue(a[self.sortColumn])
  local b = safeValue(b[self.sortColumn])
  if type(a) == type(b) then
    return a < b
  end
  return tostring(a) < tostring(b)
end

function UI.Grid:drawRows()
  local y = 1
  local startRow = math.max(1, self:getStartRow())
  local sb = UI.StringBuffer(self.width)

  if not self.disableHeader then
    y = y + 1
  end

  local lastRow = math.min(startRow + self.pageSize - 1, #self.sorted)
  for index = startRow, lastRow do

    local sindex = self.sorted[index]
    local row = self.values[sindex]
    local key = sindex
    row = self:getDisplayValues(row, key)

    sb:clear()

    local ind = ' '
    if self.focused and index == self.index and self.selectable then
      ind = self.focusIndicator
    end

    for _,col in pairs(self.columns) do
      sb:insert(ind .. safeValue(row[col.key] or ''), col.cw + 1)
      ind = ' '
    end

    local selected = index == self.index and self.selectable

    self:write(1, y, sb:get(),
      self:getRowBackgroundColor(row, selected),
      self:getRowTextColor(row, selected))

    y = y + 1
  end

  if y <= self.height then
    self:clearArea(1, y, self.width, self.height - y + 1)
  end
end

function UI.Grid:getRowTextColor(row, selected)
  if selected then
    if self.focused then
      return self.textSelectedColor
    end
    return self.unfocusedTextSelectedColor
  end
  return self.textColor
end

function UI.Grid:getRowBackgroundColor(row, selected)
  if selected then
    if self.focused then
      return self.backgroundSelectedColor
    end
    return self.unfocusedBackgroundSelectedColor
  end
  return self.backgroundColor
end

function UI.Grid:getIndex(index)
  return self.index
end

function UI.Grid:setIndex(index)
  index = math.max(1, index)
  self.index = math.min(index, #self.sorted)

  local selected = self:getSelected()
  if selected ~= self.selected then
    self:drawRows()
    self.selected = selected
    if selected then
      self:emit({ type = 'grid_focus_row', selected = selected })
    end
  end
end

function UI.Grid:getStartRow()
  return math.floor((self.index - 1) / self.pageSize) * self.pageSize + 1
end

function UI.Grid:getPage()
  return math.floor(self.index / self.pageSize) + 1
end

function UI.Grid:getPageCount()
  local tableSize = Util.size(self.values)
  local pc = math.floor(tableSize / self.pageSize)
  if tableSize % self.pageSize > 0 then
    pc = pc + 1
  end
  return pc
end

function UI.Grid:nextPage()
  self:setPage(self:getPage() + 1)
end

function UI.Grid:previousPage()
  self:setPage(self:getPage() - 1)
end

function UI.Grid:setPage(pageNo)
  -- 1 based paging
  self:setIndex((pageNo-1) * self.pageSize + 1)
end

function UI.Grid:eventHandler(event)

  if event.type == 'mouse_click' or event.type == 'mouse_doubleclick' then
    if not self.disableHeader then
      if event.y == 1 then
        local col = 2
        for _,c in ipairs(self.columns) do
          if event.x < col + c.cw then
            if self.sortColumn == c.key then
              self:setInverseSort(not self.inverseSort)
            else
              self.sortColumn = c.key
              self:setInverseSort(false)
            end
            self:draw()
            break
          end
          col = col + c.cw + 1
        end
        return true
      end
    end
    local row = self:getStartRow() + event.y - 1
    if not self.disableHeader then
      row = row - 1
    end
    if row > 0 and row <= Util.size(self.values) then
      self:setIndex(row)
      if event.type == 'mouse_doubleclick' then
        self:emit({ type = 'key_enter' })
      end
      return true
    end
    return false

  elseif event.type == 'scroll_down' then
    self:setIndex(self.index + 1)
  elseif event.type == 'scroll_up' then
    self:setIndex(self.index - 1)
  elseif event.type == 'scroll_top' then
    self:setIndex(1)
  elseif event.type == 'scroll_bottom' then
    self:setIndex(Util.size(self.values))
  elseif event.type == 'scroll_pageUp' then
    self:setIndex(self.index - self.pageSize)
  elseif event.type == 'scroll_pageDown' then
    self:setIndex(self.index + self.pageSize)
  elseif event.type == 'key_enter' then
    if self.selected then
      self:emit({ type = 'grid_select', selected = self.selected })
    end
  elseif event.type == 'copy' then
    if self.selected then
      clipboard.setData(Util.tostring(self.selected))
      clipboard.useInternal(true)
    end
  else
    return false
  end
  return true
end

--[[-- ScrollingGrid  --]]--
UI.ScrollingGrid = class(UI.Grid)
UI.ScrollingGrid.defaults = {
  UIElement = 'ScrollingGrid',
  scrollOffset = 1,
  lineChar = '|',
  sliderChar = '#',
  upArrowChar = '^',
  downArrowChar = 'v',
  scrollbarColor = colors.lightGray,
}
function UI.ScrollingGrid:init(args)
  UI.Grid.init(self, UI:getDefaults(UI.ScrollingGrid, args))
end

function UI.ScrollingGrid:drawRows()
  UI.Grid.drawRows(self)
  self:drawScrollbar()
end

function UI.ScrollingGrid:drawScrollbar()
  local ts = Util.size(self.values)
  if ts > self.pageSize then
    local maxScroll = ts - self.pageSize
    local percent = (self.scrollOffset - 1) / maxScroll
    local sliderSize = self.pageSize / ts * (self.pageSize - 2)
    local row = 2

    if self.disableHeader then
      row = 1
    end

    local x = self.width
    for i = 1, self.pageSize - 2 do
      self:write(x, row + i, self.lineChar, nil, self.scrollbarColor)
    end

    local y = Util.round((self.pageSize - 2 - sliderSize) * percent)
    for i = 1, Util.round(sliderSize) do
      self:write(x, row + y + i, self.sliderChar, nil, self.scrollbarColor)
    end

    local color = self.scrollbarColor
    if self.scrollOffset > 1 then
      color = colors.white
    end
    self:write(x, 2, self.upArrowChar, nil, color)

    color = self.scrollbarColor
    if self.scrollOffset + self.pageSize - 1 < Util.size(self.values) then
      color = colors.white
    end
    self:write(x, self.pageSize + 1, self.downArrowChar, nil, color)
  end
end

function UI.ScrollingGrid:getStartRow()
  local ts = Util.size(self.values)
  if ts < self.pageSize then
    self.scrollOffset = 1
  end
  return self.scrollOffset
end

function UI.ScrollingGrid:setIndex(index)
  if index < self.scrollOffset then
    self.scrollOffset = index
  elseif index - (self.scrollOffset - 1) > self.pageSize then
    self.scrollOffset = index - self.pageSize + 1
  end

  if self.scrollOffset < 1 then
    self.scrollOffset = 1
  else
    local ts = Util.size(self.values)
    if self.pageSize + self.scrollOffset > ts then
      self.scrollOffset = math.max(1, ts - self.pageSize + 1)
    end
  end
  UI.Grid.setIndex(self, index)
end

function UI.ScrollingGrid:eventHandler(event)

  if event.type == 'mouse_click' or event.type == 'mouse_doubleclick' then
    if event.x == self.width then
      local ts = Util.size(self.values)
      if ts > self.pageSize then
        local row = 2
        if self.disableHeader then
          row = 1
        end
        if event.y == row then
          self:setIndex(self.scrollOffset - 1)
        elseif event.y == self.height then
          self:setIndex(self.scrollOffset + self.pageSize)
        else
          -- ... percentage ...
        end
        return true
      end
    end
  end

  return UI.Grid.eventHandler(self, event)
end

--[[-- Menu --]]--
UI.Menu = class(UI.Grid)
UI.Menu.defaults = {
  UIElement = 'Menu',
  disableHeader = true,
  columns = { { heading = 'Prompt', key = 'prompt', width = 20 } },
}
function UI.Menu:init(args)
  local defaults = UI:getDefaults(UI.Menu)
  defaults.values = args['menuItems']
  UI:setProperties(defaults, args)
  UI.Grid.init(self, defaults)
  self.pageSize = #args.menuItems
end

function UI.Menu:setParent()
  UI.Grid.setParent(self)
  self.itemWidth = 1
  for _,v in pairs(self.values) do
    if #v.prompt > self.itemWidth then
      self.itemWidth = #v.prompt
    end
  end
  self.columns[1].width = self.itemWidth

  if self.centered then
    self:center()
  else
    self.width = self.itemWidth + 2
  end
end

function UI.Menu:center()
  self.x = (self.width - self.itemWidth + 2) / 2
  self.width = self.itemWidth + 2
end

function UI.Menu:eventHandler(event)
  if event.type == 'key' then
    if event.key == 'enter' then
      local selected = self.menuItems[self.index]
      self:emit({
        type = selected.event or 'menu_select',
        selected = selected
      })
      return true
    end
  elseif event.type == 'mouse_click' then
    if event.y <= #self.menuItems then
      UI.Grid.setIndex(self, event.y)
      local selected = self.menuItems[self.index]
      self:emit({
        type = selected.event or 'menu_select',
        selected = selected
      })
      return true
    end
  end
  return UI.Grid.eventHandler(self, event)
end

--[[-- ViewportWindow --]]--
UI.ViewportWindow = class(UI.Window)
UI.ViewportWindow.defaults = {
  UIElement = 'ViewportWindow',
  backgroundColor = colors.cyan,
  accelerators = {
    down            = 'scroll_down',
    up              = 'scroll_up',
    home            = 'scroll_top',
    [ 'end' ]       = 'scroll_bottom',
    pageUp          = 'scroll_pageUp',
    [ 'control-b' ] = 'scroll_pageUp',
    pageDown        = 'scroll_pageDown',
    [ 'control-f' ] = 'scroll_pageDown',
  },
}
function UI.ViewportWindow:init(args)
  local defaults = UI:getDefaults(UI.ViewportWindow, args)
  UI.Window.init(self, defaults)
end

function UI.ViewportWindow:setScrollPosition(offset)
  local oldOffset = self.offy
  self.offy = math.max(offset, 0)
  local max = self.ymax or self.height
  if self.children then
    for _, child in ipairs(self.children) do
      max = math.max(child.y + child.height - 1, max)
    end
  end
  self.offy = math.min(self.offy, math.max(max, self.height) - self.height)
  if self.offy ~= oldOffset then
    self:draw()
  end
end

function UI.ViewportWindow:reset()
  self.offy = 0
end

function UI.ViewportWindow:eventHandler(event)

  if event.type == 'scroll_down' then
    self:setScrollPosition(self.offy + 1)
  elseif event.type == 'scroll_up' then
    self:setScrollPosition(self.offy - 1)
  elseif event.type == 'scroll_top' then
    self:setScrollPosition(0)
  elseif event.type == 'scroll_bottom' then
    self:setScrollPosition(10000000)
  elseif event.type == 'scroll_pageUp' then
    self:setScrollPosition(self.offy - self.height)
  elseif event.type == 'scroll_pageDown' then
    self:setScrollPosition(self.offy + self.height)
  else
    return false
  end
  return true
end
  
--[[-- ScrollingText --]]--
UI.ScrollingText = class(UI.Window)
UI.ScrollingText.defaults = {
  UIElement = 'ScrollingText',
  backgroundColor = colors.black,
  buffer = { },
}
function UI.ScrollingText:init(args)
  local defaults = UI:getDefaults(UI.ScrollingText, args)
  UI.Window.init(self, defaults)
end

function UI.ScrollingText:appendLine(text)
  if #self.buffer+1 >= self.height then
    table.remove(self.buffer, 1)
  end
  table.insert(self.buffer, text)
end

function UI.ScrollingText:clear()
  self.buffer = { }
  UI.Window.clear(self)
end

function UI.ScrollingText:draw()
  for k,text in ipairs(self.buffer) do
    self:write(1, k, Util.widthify(text, self.width), self.backgroundColor)
  end
end

--[[-- TitleBar --]]--
UI.TitleBar = class(UI.Window)
UI.TitleBar.defaults = {
  UIElement = 'TitleBar',
  height = 1,
  textColor = colors.lightGray,
  backgroundColor = colors.gray,
  title = '',
  frameChar = '-',
  closeInd = '*',
}
function UI.TitleBar:init(args)
  local defaults = UI:getDefaults(UI.TitleBar, args)
  UI.Window.init(self, defaults)
end

function UI.TitleBar:draw()
  local sb = SB:new(self.width)
  sb:fill(2, self.frameChar, sb.width - 3)
  sb:center(string.format(' %s ', self.title))
  if self.previousPage or self.event then
    sb:insert(-1, self.closeInd)
  end
  self:write(1, 1, sb:get())
end

function UI.TitleBar:eventHandler(event)
  if event.type == 'mouse_click' then
    if (self.previousPage or self.event) and event.x == self.width then
      if self.event then
        self:emit({ type = self.event, element = self })
      elseif type(self.previousPage) == 'string' or
         type(self.previousPage) == 'table' then
        UI:setPage(self.previousPage)
      else
        UI:setPreviousPage()
      end
      return true
    end
  end
end

--[[-- MenuBar --]]--
UI.MenuBar = class(UI.Window)
UI.MenuBar.defaults = {
  UIElement = 'MenuBar',
  buttons = { },
  height = 1,
  backgroundColor = colors.lightGray,
  textColor = colors.black,
  spacing = 2,
  showBackButton = false,
}

function UI.MenuBar:init(args)
  local defaults = UI:getDefaults(UI.MenuBar, args)
  UI:setProperties(self, defaults)

  if not self.children then
    self.children = { }
  end

  local x = 1
  for k,button in pairs(self.buttons) do
    if button.UIElement then
      table.insert(self.children, button)
    else
      local buttonProperties = {
        x = x,
        width = #button.text + self.spacing,
        centered = false,
      }
      x = x + buttonProperties.width
      UI:setProperties(buttonProperties, button)
      if button.name then
        self[button.name] = UI.MenuItem(buttonProperties)
      else
        table.insert(self.children, UI.MenuItem(buttonProperties))
      end
    end
  end
  if self.showBackButton then
    table.insert(self.children, UI.MenuItem({
      x = UI.term.width - 2,
      width = 3,
      backgroundColor = self.backgroundColor,
      textColor = self.textColor,
      text = '^-',
      event = 'back',
    }))
  end
  UI.Window.init(self, defaults)
end

function UI.MenuBar:eventHandler(event)
  if event.type == 'dropdown' then
    -- better, but still a bad implementation
    -- this at least will allow overrides
    -- on the button and menubar
    if event.button and event.button.dropdown then
      local dropdown = self.parent[event.button.dropdown]
      if dropdown then
        if dropdown.enabled then
          dropdown:hide(event.button)
        else
          dropdown:show(event.button)
        end
        return true
      end
    end
  end
end

--[[-- DropMenu --]]--
UI.DropMenu = class(UI.MenuBar)
UI.DropMenu.defaults = {
  UIElement = 'DropMenu',
  backgroundColor = colors.lightGray,
}
function UI.DropMenu:init(args)
  local defaults = UI:getDefaults(UI.DropMenu, args)
  UI.MenuBar.init(self, defaults)
end

function UI.DropMenu:setParent()
  UI.MenuBar.setParent(self)

  local maxWidth = 1
  for y,child in ipairs(self.children) do
    child.x = 1
    child.y = y
    if #(child.text or '') > maxWidth then
      maxWidth = #child.text
    end
  end
  for _,child in ipairs(self.children) do
    child.width = maxWidth + 2
  end

  self.height = #self.children
  self.width = maxWidth + 2
  self.ow = self.width
end

function UI.DropMenu:enable()
  self.enabled = false
end

function UI.DropMenu:show(button) -- the x, y should be passed instead of button
  self.button = button
  self.x, self.y = getPosition(button)
  self.y = self.y + 1
  if self.x + self.width > self.parent.width then
    self.x = self.parent.width - self.width + 1
  end
  self.enabled = true
  for _,child in ipairs(self.children) do
    child:enable()
  end
  self:setFocus(self.children[1])
  self:draw()
  UI:capture(self)
end

function UI.DropMenu:hide()
  self:disable()
  self.parent:draw()
  UI:release(self)
end

function UI.DropMenu:eventHandler(event)
  if event.type == 'focus_lost' then
    for _,child in ipairs(self.children) do
      if child == event.focused then
        return
      end
    end
    self:hide()
  elseif event.type == 'mouse_out' then
    self:hide()
    if self.button then
      self:setFocus(self.button)
    end
  else
    return UI.MenuBar.eventHandler(self, event)
  end
  return true
end

--[[-- TabBar --]]--
UI.TabBar = class(UI.MenuBar)
UI.TabBar.defaults = {
  UIElement = 'TabBar',
  selectedBackgroundColor = colors.cyan,
  focusBackgroundColor = colors.green,
}
function UI.TabBar:init(args)
  local defaults = UI:getDefaults(UI.TabBar, args)
  UI.MenuBar.init(self, defaults)
end

function UI.TabBar:selectTab(text)
  local selected, lastSelected
  for k,child in pairs(self.children) do
    if child.selected then
      lastSelected = k
    end
    child.selected = child.text == text
    if child.selected then
      selected = k
      child.backgroundColor = self.selectedBackgroundColor
      child.backgroundFocusColor = self.selectedBackgroundColor
    else
      child.backgroundColor = self.backgroundColor
      child.backgroundFocusColor = self.backgroundColor
    end
  end
  if selected and lastSelected and selected ~= lastSelected then
    self:emit({ type = 'tab_change', current = selected, last = lastSelected })
  end
  UI.MenuBar.draw(self)
end

--[[-- Tabs --]]--
UI.Tabs = class(UI.Window)
UI.Tabs.defaults = {
  UIElement = 'Tabs',
}
function UI.Tabs:init(args)
  local defaults = UI:getDefaults(UI.Tabs, args)

  local buttons = { }
  for k,child in pairs(defaults) do
    if type(child) == 'table' and child.UIElement then
      table.insert(buttons, {
        text = child.tabTitle or '', event = 'tab_select',
      })
    end
  end

  self.tabBar = UI.TabBar({
    buttons = buttons,
  })

  UI.Window.init(self, defaults)
end

function UI.Tabs:setParent()
  UI.Window.setParent(self)

  for _,child in pairs(self.children) do
    if child ~= self.tabBar then
      child.oy = 2
      --child.height = self.height - 1
      child:resize()
    end
  end
end

function UI.Tabs:enable()
  self.enabled = true
  for _,child in ipairs(self.children) do
    if child.tabTitle == self.tabBar.buttons[1].text then
      self:activateTab(child)
      break
    end
  end
  self.tabBar:enable()
end

function UI.Tabs:activateTab(tab)
  for _,child in ipairs(self.children) do
    if child ~= self.tabBar then
      child:disable()
    end
  end
  self.tabBar:selectTab(tab.tabTitle)
  tab:enable()
  tab:draw()
  self:emit({ type = 'tab_activate', activated = tab, element = self })
end

function UI.Tabs:eventHandler(event)
  if event.type == 'tab_select' then
    for _,child in ipairs(self.children) do
      if child.tabTitle == event.button.text then
        self:activateTab(child)
        break
      end
    end
  elseif event.type == 'tab_change' then
    for _,tab in ipairs(self.children) do
      if tab ~= self.tabBar then
        if event.current > event.last then
          tab:addTransition('slideLeft')
        else
          tab:addTransition('slideRight')
        end
        break
      end
    end
  end
end

--[[-- WindowScroller --]]--
UI.WindowScroller = class(UI.Window)
UI.WindowScroller.defaults = {
  UIElement = 'WindowScroller',
  children = { },
}
function UI.WindowScroller:init(args)
  local defaults = UI:getDefaults(UI.WindowScroller, args)
  UI.Window.init(self, defaults)
end

function UI.WindowScroller:enable()
  self.enabled = true
  if #self.children > 0 then
    self.children[1]:enable()
  end
end

function UI.WindowScroller:nextChild()
  for i = 1, #self.children do
    if self.children[i].enabled then
      if i < #self.children then
        self:addTransition('slideLeft')
        self.children[i]:disable()
        self.children[i + 1]:enable()
      end
      break
    end
  end
end

function UI.WindowScroller:prevChild()
  for i = 1, #self.children do
    if self.children[i].enabled then
      if i - 1 > 0 then
        self:addTransition('slideRight')
        self.children[i]:disable()
        self.children[i - 1]:enable()
      end
      break
    end
  end
end

--[[-- Notification --]]--
UI.Notification = class(UI.Window)
UI.Notification.defaults = {
  UIElement = 'Notification',
  backgroundColor = colors.gray,
  height = 3,
}
function UI.Notification:init(args)
  local defaults = UI:getDefaults(UI.Notification, args)
  UI.Window.init(self, defaults)
end

function UI.Notification:draw()
end

function UI.Notification:enable()
  self.enabled = false
end

function UI.Notification:error(value, timeout)
  self.backgroundColor = colors.red
  self:display(value, timeout)
end

function UI.Notification:info(value, timeout)
  self.backgroundColor = colors.gray
  self:display(value, timeout)
end

function UI.Notification:success(value, timeout)
  self.backgroundColor = colors.green
  self:display(value, timeout)
end

function UI.Notification:cancel()
  if self.canvas then
    Event.cancelNamedTimer('notificationTimer')
    self.enabled = false
    self.canvas:removeLayer()
    self.canvas = nil
  end
end

function UI.Notification:display(value, timeout)
  self.enabled = true
  local lines = Util.wordWrap(value, self.width - 2)
  self.height = #lines + 1
  self.y = self.parent.height - self.height + 1
  if self.canvas then
    self.canvas:removeLayer()
  end

  -- need to get the current canvas - not ui.term.canvas
  self.canvas = UI.term.canvas:addLayer(self, self.backgroundColor, self.textColor or colors.white)
  self:addTransition('expandUp', { ticks = self.height })
  self.canvas:setVisible(true)
  self:clear()
  for k,v in pairs(lines) do
    self:write(2, k, v)
  end

  Event.addNamedTimer('notificationTimer', timeout or 3, false, function()
    self:cancel()
    self:sync()
  end)
end

--[[-- Throttle --]]--
UI.Throttle = class(UI.Window)
UI.Throttle.defaults = {
  UIElement = 'Throttle',
  backgroundColor = colors.gray,
  height = 6,
  width = 10,
  timeout = .095,
  ctr = 0,
  image = {
    '  //)    (O )~@ &~&-( ?Q        ',
    '  //)    (O )- @  \-( ?)  &&    ',
    '  //)    (O ), @  \-(?)     &&  ',
    '  //)    (O ). @  \-d )      (@ '
  }
}

function UI.Throttle:init(args)
  local defaults = UI:getDefaults(UI.Throttle, args)
  UI.Window.init(self, defaults)
end

function UI.Throttle:setParent()
  self.x = math.ceil((self.parent.width - self.width) / 2)
  self.y = math.ceil((self.parent.height - self.height) / 2)
  UI.Window.setParent(self)
end

function UI.Throttle:enable()
  self.enabled = false
end

function UI.Throttle:disable()
  if self.canvas then
    self.enabled = false
    self.canvas:removeLayer()
    self.canvas = nil
    self.c = nil
  end
end

function UI.Throttle:update()
  local cc = os.clock()
  if not self.c then
    self.c = cc
  elseif cc > self.c + self.timeout then
    os.sleep(0)
    self.c = os.clock()
    self.enabled = true
    if not self.canvas then
      self.canvas = UI.term.canvas:addLayer(self, self.backgroundColor, colors.cyan)
      self.canvas:setVisible(true)
      self:clear(colors.cyan)
    end
    local image = self.image[self.ctr + 1]
    local width = self.width - 2
    for i = 0, #self.image do
      self:write(2, i + 2, image:sub(width * i + 1, width * i + width), colors.black, colors.white)
    end

    self.ctr = (self.ctr + 1) % #self.image

    self:sync()
  end
end

--[[-- StatusBar --]]--
UI.StatusBar = class(UI.Window)
UI.StatusBar.defaults = {
  UIElement = 'StatusBar',
  backgroundColor = colors.lightGray,
  textColor = colors.gray,
  height = 1,
  ey = -1,
}
function UI.StatusBar:init(args)
  local defaults = UI:getDefaults(UI.StatusBar, args)
  UI.Window.init(self, defaults)
end

function UI.StatusBar:adjustWidth()
  -- Can only have 1 adjustable width
  if self.columns then
    local w = self.width - #self.columns - 1
    for _,c in pairs(self.columns) do
      if c.width then
        c.cw = c.width  -- computed width
        w = w - c.width
      end
    end
    for _,c in pairs(self.columns) do
      if not c.width then
        c.cw = w
      end
    end
  end
end

function UI.StatusBar:resize()
  UI.Window.resize(self)
  self:adjustWidth()
end

function UI.StatusBar:setParent()
  UI.Window.setParent(self)
  self:adjustWidth()
end

function UI.StatusBar:setStatus(status)
  if self.values ~= status then
    self.values = status
    self:draw()
  end
end

function UI.StatusBar:setValue(name, value)
  if not self.values then
    self.values = { }
  end
  self.values[name] = value
end

function UI.StatusBar:getValue(name)
  if self.values then
    return self.values[name]
  end
end

function UI.StatusBar:timedStatus(status, timeout)
  timeout = timeout or 3
  self:write(2, 1, Util.widthify(status, self.width-2), self.backgroundColor)
  Event.addNamedTimer('statusTimer', timeout, false, function()
    if self.parent.enabled then
      self:draw()
      self:sync()
    end
  end)
end

function UI.StatusBar:getColumnWidth(name)
  for _,c in pairs(self.columns) do
    if c.key == name then
      return c.cw
    end
  end
end

function UI.StatusBar:setColumnWidth(name, width)
  for _,c in pairs(self.columns) do
    if c.key == name then
      c.cw = width
      break
    end
  end
end

function UI.StatusBar:draw()
  if not self.values then
    self:clear()
  elseif type(self.values) == 'string' then
    self:write(1, 1, Util.widthify(' ' .. self.values, self.width))
  else
    local s = ''
    for _,c in ipairs(self.columns) do
      s = s .. ' ' .. Util.widthify(tostring(self.values[c.key] or ''), c.cw)
    end
    self:write(1, 1, Util.widthify(s, self.width))
  end
end

--[[-- ProgressBar --]]--
UI.ProgressBar = class(UI.Window)
UI.ProgressBar.defaults = {
  UIElement = 'ProgressBar',
  progressColor = colors.lime,
  backgroundColor = colors.gray,
  height = 1,
  value = 0,
}
function UI.ProgressBar:init(args)
  local defaults = UI:getDefaults(UI.ProgressBar, args)
  UI.Window.init(self, defaults)
end

function UI.ProgressBar:draw()
  self:clear()
  local width = math.ceil(self.value / 100 * self.width)
  self:clearArea(1, 1, width, self.height, self.progressColor)
end

--[[-- VerticalMeter --]]--
UI.VerticalMeter = class(UI.Window)
UI.VerticalMeter.defaults = {
  UIElement = 'VerticalMeter',
  backgroundColor = colors.gray,
  meterColor = colors.lime,
  width = 1,
  value = 0,
}
function UI.VerticalMeter:init(args)
  local defaults = UI:getDefaults(UI.VerticalMeter, args)
  UI.Window.init(self, defaults)
end

function UI.VerticalMeter:draw()
  local height = self.height - math.ceil(self.value / 100 * self.height)
  self:clear()
  self:clearArea(1, height + 1, self.width, self.height, self.meterColor)
end

--[[-- Button --]]--
UI.Button = class(UI.Window)
UI.Button.defaults = {
  UIElement = 'Button',
  text = 'button',
  backgroundColor = colors.gray,
  backgroundFocusColor = colors.lightGray,
  textFocusColor = colors.white,
  textColor = colors.white,
  centered = true,
  height = 1,
  focusIndicator = '>',
  event = 'button_press',
  accelerators = {
    space = 'button_activate',
    enter = 'button_activate',
    mouse_click = 'button_activate',
  }
}
function UI.Button:init(args)
  local defaults = UI:getDefaults(UI.Button, args)
  UI.Window.init(self, defaults)
end

function UI.Button:setParent()
  if not self.width and not self.ex then
    self.width = #self.text + 2
  end
  UI.Window.setParent(self)
end

function UI.Button:draw()
  local fg = self.textColor
  local bg = self.backgroundColor
  local ind = ' '
  if self.focused then
    bg = self.backgroundFocusColor
    fg = self.textFocusColor
    ind = self.focusIndicator
  end
  self:clear(bg)
  local text = ind .. self.text .. ' '
  if self.centered then
    self:centeredWrite(1 + math.floor(self.height / 2), text, bg, fg)
  else
    self:write(1, 1, Util.widthify(text, self.width), bg, fg)
  end
end

function UI.Button:focus()
  if self.focused then
    self:scrollIntoView()
  end
  self:draw()
end

function UI.Button:eventHandler(event)
  if event.type == 'button_activate' then
    self:emit({ type = self.event, button = self })
    return true
  end
  return false
end

--[[-- MenuItem --]]--
UI.MenuItem = class(UI.Button)
UI.MenuItem.defaults = {
  UIElement = 'MenuItem',
  textColor = colors.black,
  backgroundColor = colors.lightGray,
  textFocusColor = colors.white,
  backgroundFocusColor = colors.lightGray,
}

function UI.MenuItem:init(args)
  local defaults = UI:getDefaults(UI.MenuItem, args)
  UI.Button.init(self, defaults)
end

--[[-- TextEntry --]]--
UI.TextEntry = class(UI.Window)
UI.TextEntry.defaults = {
  UIElement = 'TextEntry',
  value = '',
  shadowText = '',
  focused = false,
  textColor = colors.white,
  backgroundColor = colors.black, -- colors.lightGray,
  backgroundFocusColor = colors.black, --lightGray,
  height = 1,
  limit = 6,
  pos = 0,
  accelerators = {
    [ 'control-c' ] = 'copy',
  }
}
function UI.TextEntry:init(args)
  local defaults = UI:getDefaults(UI.TextEntry, args)
  UI.Window.init(self, defaults)
  self.value = tostring(self.value)
end

function UI.TextEntry:setValue(value)
  self.value = value
end

function UI.TextEntry:setPosition(pos)
  self.pos = pos
end

function UI.TextEntry:updateScroll()
  if not self.scroll then
    self.scroll = 0
  end

  if not self.pos then
    self.pos = #tostring(self.value)
    self.scroll = 0
  elseif self.pos > #tostring(self.value) then
    self.pos = #tostring(self.value)
    self.scroll = 0
  end

  if self.pos - self.scroll > self.width - 2 then
    self.scroll = self.pos - (self.width - 2)
  elseif self.pos < self.scroll then
    self.scroll = self.pos
  end

  --debug('p:%d s:%d w:%d l:%d', self.pos, self.scroll, self.width, self.limit)
end

function UI.TextEntry:draw()
  local bg = self.backgroundColor
  local tc = self.textColor
  if self.focused then
    bg = self.backgroundFocusColor
  end

  self:updateScroll()
  local text = tostring(self.value)
  if #text > 0 then
    if self.scroll and self.scroll > 0 then
      text = text:sub(1 + self.scroll)
    end
  else
    tc = colors.gray
    text = self.shadowText
  end

  self:write(1, 1, ' ' .. Util.widthify(text, self.width - 2) .. ' ', bg, tc)
  if self.focused then
    self:setCursorPos(self.pos-self.scroll+2, 1)
  end
end

function UI.TextEntry:reset()
  self.pos = 0
  self.value = ''
  self:draw()
  self:updateCursor()
end

function UI.TextEntry:updateCursor()
  self:updateScroll()
  self:setCursorPos(self.pos-self.scroll+2, 1)
end

function UI.TextEntry:focus()
  self:draw()
  if self.focused then
    self:setCursorBlink(true)
  else
    self:setCursorBlink(false)
  end
end

--[[
  A few lines below from theoriginalbit
  http://www.computercraft.info/forums2/index.php?/topic/16070-read-and-limit-length-of-the-input-field/
--]]
function UI.TextEntry:eventHandler(event)
  if event.type == 'key' then
    local ch = event.key
    if ch == 'left' then
      if self.pos > 0 then
        self.pos = math.max(self.pos-1, 0)
        self:draw()
      end
    elseif ch == 'right' then
      local input = tostring(self.value)
      if self.pos < #input then
        self.pos = math.min(self.pos+1, #input)
        self:draw()
      end
    elseif ch == 'home' then
      self.pos = 0
      self:draw()
    elseif ch == 'end' then
      self.pos = #tostring(self.value)
      self:draw()
    elseif ch == 'backspace' then
      if self.pos > 0 then
        local input = tostring(self.value)
        self.value = input:sub(1, self.pos-1) .. input:sub(self.pos+1)
        self.pos = self.pos - 1
        self:draw()
        self:emit({ type = 'text_change', text = self.value })
      end
    elseif ch == 'delete' then
      local input = tostring(self.value)
      if self.pos < #input then
        self.value = input:sub(1, self.pos) .. input:sub(self.pos+2)
        self:draw()
        self:emit({ type = 'text_change', text = self.value })
      end
    elseif #ch == 1 then
      local input = tostring(self.value)
      if #input < self.limit then
        self.value = input:sub(1, self.pos) .. ch .. input:sub(self.pos+1)
        self.pos = self.pos + 1
        self:draw()
        self:emit({ type = 'text_change', text = self.value })
      end
    else
      return false
    end
    return true

  elseif event.type == 'copy' then
    clipboard.setData(self.value)

  elseif event.type == 'paste' then
    local input = tostring(self.value)
    local text = event.text
    if #input + #text > self.limit then
      text = text:sub(1, self.limit-#input)
    end
    self.value = input:sub(1, self.pos) .. text .. input:sub(self.pos+1)
    self.pos = self.pos + #text
    self:draw()
    self:updateCursor()
    self:emit({ type = 'text_change', text = self.value })
    return true

  elseif event.type == 'mouse_click' then
    if self.focused and event.x > 1 then
      self.pos = event.x + self.scroll - 2
      self:updateCursor()
      return true
    end
  elseif event.type == 'mouse_rightclick' then
    local input = tostring(self.value)
    if #input > 0 then
      self:reset()
      self:emit({ type = 'text_change', text = self.value })
    end
  end

  return false
end

--[[-- Chooser --]]--
UI.Chooser = class(UI.Window)
UI.Chooser.defaults = {
  UIElement = 'Chooser',
  choices = { },
  nochoice = 'Select',
  --backgroundColor = colors.lightGray,
  backgroundFocusColor = colors.lightGray,
  height = 1,
}
function UI.Chooser:init(args)
  local defaults = UI:getDefaults(UI.Chooser, args)
  UI.Window.init(self, defaults)
end

function UI.Chooser:setParent()
  if not self.width and not self.ex then
    self.width = 1
    for _,v in pairs(self.choices) do
      if #v.name > self.width then
        self.width = #v.name
      end
    end
    self.width = self.width + 4
  end
  UI.Window.setParent(self)
end

function UI.Chooser:draw()
  local bg = self.backgroundColor
  if self.focused then
    bg = self.backgroundFocusColor
  end
  local choice = Util.find(self.choices, 'value', self.value)
  local value = self.nochoice
  if choice then
    value = choice.name
  end
  self:write(1, 1, '<', bg, colors.black)
  self:write(2, 1, ' ' .. Util.widthify(value, self.width-4) .. ' ', bg)
  self:write(self.width, 1, '>', bg, colors.black)
end

function UI.Chooser:focus()
  self:draw()
end

function UI.Chooser:eventHandler(event)
  if event.type == 'key' then
    if event.key == 'right' or event.key == 'space' then
      local choice,k = Util.find(self.choices, 'value', self.value)
      if k and k < #self.choices then
        self.value = self.choices[k+1].value
      else
        self.value = self.choices[1].value
      end
      self:emit({ type = 'choice_change', value = self.value })
      self:draw()
      return true
    elseif event.key == 'left' then
      local choice,k = Util.find(self.choices, 'value', self.value)
      if k and k > 1 then
        self.value = self.choices[k-1].value
      else
        self.value = self.choices[#self.choices].value
      end
      self:emit({ type = 'choice_change', value = self.value })
      self:draw()
      return true
    end
  elseif event.type == 'mouse_click' then
    if event.x == 1 then
      self:emit({ type = 'key', key = 'left' })
      return true
    elseif event.x == self.width then
      self:emit({ type = 'key', key = 'right' })
      return true
    end
  end
end

--[[-- Text --]]--
UI.Text = class(UI.Window)
UI.Text.defaults = {
  UIElement = 'Text',
  value = '',
  height = 1,
}
function UI.Text:init(args)
  local defaults = UI:getDefaults(UI.Text, args)
  UI.Window.init(self, defaults)
end

function UI.Text:setParent()
  if not self.width and not self.ex then
    self.width = #tostring(self.value)
  end
  UI.Window.setParent(self)
end

function UI.Text:draw()
  local value = self.value or ''
  self:write(1, 1, Util.widthify(value, self.width), self.backgroundColor)
end

--[[-- TextArea --]]--
UI.TextArea = class(UI.Window)
UI.TextArea.defaults = {
  UIElement = 'TextArea',
  value = '',
}
function UI.TextArea:init(args)
  local defaults = UI:getDefaults(UI.TextArea, args)
  UI.Window.init(self, defaults)
end

function UI.TextArea:setText(text)
  self.value = text
  self:draw()
end

function UI.TextArea:draw()
  local value = self.value or ''
  self:clear()
  self:setCursorPos(1, 1)
  self:print(self.value)
end

--[[-- Form --]]--
UI.Form = class(UI.Window)
UI.Form.defaults = {
  UIElement = 'Form',
  values = { },
  margin = 2,
  event = 'form_complete',
}
function UI.Form:init(args)
  local defaults = UI:getDefaults(UI.Form, args)
  UI.Window.init(self, defaults)
  self:createForm()
end

function UI.Form:reset()
  for _,child in pairs(self.children) do
    if child.reset then
      child:reset()
    end
  end
end

function UI.Form:setValues(values)
  self:reset()
  self.values = values
  for k,child in pairs(self.children) do
    if child.formKey then
      -- this should be child:setValue(self.values[child.formKey])
      -- so chooser can set default choice if null
      -- null should be valid as well
      child.value = self.values[child.formKey] or ''
    end
  end
end

function UI.Form:createForm()
  self.children = self.children or { }

  if not self.labelWidth then
    self.labelWidth = 1
    for _, child in pairs(self) do
      if type(child) == 'table' and child.UIElement then
        if child.formLabel then
          self.labelWidth = math.max(self.labelWidth, #child.formLabel + 2)
        end
      end
    end
  end
 
  local y = self.margin
  for _, child in pairs(self) do
    if type(child) == 'table' and child.UIElement then
      if child.formKey then
        child.x = self.labelWidth + self.margin - 1
        child.y = y
        if not child.width and not child.ex then
          child.ex = -self.margin
        end
        child.value = self.values[child.formKey] or ''
      end
      if child.formLabel then
        table.insert(self.children, UI.Text {
          x = self.margin,
          y = y,
          textColor = colors.black,
          width = #child.formLabel,
          value = child.formLabel,
        })
      end
      if child.formKey or child.formLabel then
        y = y + 1
      end
    end
  end

  table.insert(self.children, UI.Button {
    y = -self.margin, x = -12 - self.margin,
    text = 'Ok',
    event = 'form_ok',
  })
  table.insert(self.children, UI.Button {
    y = -self.margin, x = -7 - self.margin,
    text = 'Cancel',
    event = 'form_cancel',
  })
end

function UI.Form:validateField(field)
  if field.required then
    if not field.value or #field.value == 0 then
      return false, 'Field is required'
    end
  end
  return true
end

function UI.Form:eventHandler(event)
  if event.type == 'form_ok' then
    for _,child in pairs(self.children) do
      if child.formKey  then
        local s, m = self:validateField(child)
        if not s then
          self:setFocus(child)
          self:emit({ type = 'form_invalid', message = m, field = child })
          return false
        end
      end
    end
    for _,child in pairs(self.children) do
      if child.formKey then
        self.values[child.formKey] = child.value
      end
    end
    self:emit({ type = self.event, UIElement = self })
  else
    return UI.Window.eventHandler(self, event)
  end
  return true
end

--[[-- Dialog --]]--
UI.Dialog = class(UI.Page)
UI.Dialog.defaults = {
  UIElement = 'Dialog',
  x = 7,
  y = 4,
  z = 2,
  height = 7,
  textColor = colors.black,
  backgroundColor = colors.white,
}
function UI.Dialog:init(args)
  local defaults = UI:getDefaults(UI.Dialog, args)

  if not defaults.width then
    defaults.width = UI.term.width-11
  end
  defaults.titleBar = UI.TitleBar({ previousPage = true, title = defaults.title })
  UI.Page.init(self, defaults)
end

function UI.Dialog:setParent()
  UI.Window.setParent(self)
  self.x = math.floor((self.parent.width - self.width) / 2) + 1
  self.y = math.floor((self.parent.height - self.height) / 2) + 1
end

function UI.Dialog:enable(...)
  self:addTransition('grow')
  UI.Page.enable(self, ...)
end

function UI.Dialog:eventHandler(event)
  if event.type == 'cancel' then
    UI:setPreviousPage()
  end
  return UI.Page.eventHandler(self, event)
end

--[[-- Image --]]--
UI.Image = class(UI.Window)
UI.Image.defaults = {
  UIElement = 'Image',
  event = 'button_press',
}
function UI.Image:init(args)
  local defaults = UI:getDefaults(UI.Image, args)
  UI.Window.init(self, defaults)
end

function UI.Image:setParent()
  if self.image then
    self.height = #self.image
  end
  if self.image and not self.width then
    self.width = #self.image[1]
  end
  UI.Window.setParent(self)
end

function UI.Image:draw()
  self:clear()
  if self.image then
    for y = 1, #self.image do
      local line = self.image[y]
      for x = 1, #line do
        local ch = line[x]
        if type(ch) == 'number' then
          if ch > 0 then
            self:write(x, y, ' ', ch)
          end
        else
          self:write(x, y, ch)
        end
      end
    end
  end
end

function UI.Image:setImage(image)
  self.image = image
end

--[[-- NftImage --]]--
UI.NftImage = class(UI.Window)
UI.NftImage.defaults = {
  UIElement = 'NftImage',
  event = 'button_press',
}
function UI.NftImage:init(args)
  local defaults = UI:getDefaults(UI.NftImage, args)
  UI.Window.init(self, defaults)
end

function UI.NftImage:setParent()
  if self.image then
    self.height = self.image.height
  end
  if self.image and not self.width then
    self.width = self.image.width
  end
  UI.Window.setParent(self)
end

function UI.NftImage:draw()
--  self:clear()
  if self.image then
    for y = 1, self.image.height do
      for x = 1, #self.image.text[y] do
        self:write(x, y, self.image.text[y][x], self.image.bg[y][x], self.image.fg[y][x])
      end
    end
  else
    self:clear()
  end
end

function UI.NftImage:setImage(image)
  self.image = image
end

UI:loadTheme('usr/config/ui.theme')
if Util.getVersion() >= 1.79 then
  UI:loadTheme('sys/etc/ext.theme')
end

UI:setDefaultDevice(UI.Device({ device = term.current() }))

return UI
