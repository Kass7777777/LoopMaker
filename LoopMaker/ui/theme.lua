local M = {}

M.colors = {
  Text = 0xE7ECEAFF, TextDisabled = 0x929E98FF,
  WindowBg = 0x202422FF, ChildBg = 0x202422FF,
  PopupBg = 0x282D2AFF, Border = 0x414B45FF,
  FrameBg = 0x2D3430FF, FrameBgHovered = 0x39473FFF,
  FrameBgActive = 0x40594CFF, CheckMark = 0x6DCCADFF,
  SliderGrab = 0x55AF92FF, SliderGrabActive = 0x80D9B9FF,
  Button = 0x343D37FF, ButtonHovered = 0x44554AFF,
  ButtonActive = 0x52675AFF, Header = 0x303A33FF,
  HeaderHovered = 0x3E5045FF, HeaderActive = 0x485F50FF,
  Separator = 0x424D46FF, ScrollbarBg = 0x202422FF,
  ScrollbarGrab = 0x48574DFF, ScrollbarGrabHovered = 0x5E7365FF,
  ScrollbarGrabActive = 0x77A48AFF, TextSelectedBg = 0x4C9D8070,
  TitleBg = 0x202422FF, TitleBgActive = 0x28352DFF,
}
M.primary = { Text = 0xFFFFFFFF, Button = 0x2F765FFF, ButtonHovered = 0x338267FF,
  ButtonActive = 0x286450FF }

function M.font_size(api, ctx)
  return type(api.ImGui_GetFontSize) == "function" and api.ImGui_GetFontSize(ctx) or 13
end

-- Each scope owns only the styles it successfully pushed, including on errors.
function M.scope(api, ctx, colors, vars, callback)
  local color_count, var_count = 0, 0
  local result = table.pack(xpcall(function()
    if api.ImGui_PushStyleColor and api.ImGui_PopStyleColor then
      for name, value in pairs(colors or {}) do
        local enum = api["ImGui_Col_" .. name]
        if enum then
          api.ImGui_PushStyleColor(ctx, enum(), value)
          color_count = color_count + 1
        end
      end
    end
    if api.ImGui_PushStyleVar and api.ImGui_PopStyleVar then
      for name, values in pairs(vars or {}) do
        local enum = api["ImGui_StyleVar_" .. name]
        if enum then
          api.ImGui_PushStyleVar(ctx, enum(), table.unpack(values))
          var_count = var_count + 1
        end
      end
    end
    return callback()
  end, debug.traceback))
  if var_count > 0 then api.ImGui_PopStyleVar(ctx, var_count) end
  if color_count > 0 then api.ImGui_PopStyleColor(ctx, color_count) end
  if not result[1] then error(result[2], 0) end
  return table.unpack(result, 2, result.n)
end

function M.window(api, ctx, callback)
  local u = M.font_size(api, ctx)
  return M.scope(api, ctx, M.colors, {
    WindowPadding = { u, u * 0.8 }, FramePadding = { u * 0.65, u * 0.4 },
    ItemSpacing = { u * 0.6, u * 0.55 }, ItemInnerSpacing = { u * 0.6, u * 0.4 },
    WindowRounding = { u * 0.6 }, FrameRounding = { u * 0.35 },
    GrabRounding = { u * 0.3 }, ScrollbarRounding = { u * 0.4 },
    ScrollbarSize = { u * 0.8 }, GrabMinSize = { u * 1.2 },
    WindowBorderSize = { 1 }, ChildBorderSize = { 0 },
  }, callback)
end

return M
