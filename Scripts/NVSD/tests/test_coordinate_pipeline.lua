-- Coordinate pipeline regression tests
-- Tests the pure logic of compute_so, abs_source_start, and branch selection
-- without requiring REAPER APIs.

----------------------------------------------------------------------
-- compute_so equivalence tests
----------------------------------------------------------------------
-- Simulate compute_so logic with explicit parameters
local function compute_so_sim(view_start_offset, source_length, is_loop_src, has_section, section_offset)
  local so = view_start_offset
  if source_length > 0 and is_loop_src and so >= source_length then so = so % source_length end
  if is_loop_src and has_section then so = so + section_offset end
  return so
end

test("compute_so: no loop, no section", function()
  local so = compute_so_sim(1.5, 10.0, false, false, 0)
  assert_eq(so, 1.5, "should pass through unchanged")
end)

test("compute_so: loop ON, offset < source_length", function()
  local so = compute_so_sim(3.0, 10.0, true, false, 0)
  assert_eq(so, 3.0, "should not wrap when offset < source_length")
end)

test("compute_so: loop ON, offset > source_length (modulo wrap)", function()
  local so = compute_so_sim(12.5, 10.0, true, false, 0)
  assert_eq(so, 2.5, "should wrap via modulo")
end)

test("compute_so: loop ON, offset == source_length", function()
  local so = compute_so_sim(10.0, 10.0, true, false, 0)
  assert_eq(so, 0.0, "should wrap to 0")
end)

test("compute_so: loop ON, with section", function()
  local so = compute_so_sim(2.0, 10.0, true, true, 5.0)
  assert_eq(so, 7.0, "should add section_offset")
end)

test("compute_so: loop ON, wrap + section", function()
  local so = compute_so_sim(15.0, 10.0, true, true, 3.0)
  assert_eq(so, 8.0, "should wrap then add section_offset")
end)

test("compute_so: source_length == 0 (guard)", function()
  local so = compute_so_sim(5.0, 0, true, false, 0)
  assert_eq(so, 5.0, "should not wrap when source_length == 0")
end)

----------------------------------------------------------------------
-- abs_source_start computation tests
----------------------------------------------------------------------
local function compute_abs(section_offset, take_offset, source_item_length)
  local start_offset = section_offset + take_offset
  local abs_start = start_offset
  local abs_end = start_offset + source_item_length
  return abs_start, abs_end
end

test("abs_source_start: no section", function()
  local s, e = compute_abs(0, 1.5, 3.0)
  assert_eq(s, 1.5, "start")
  assert_eq(e, 4.5, "end")
end)

test("abs_source_start: with section", function()
  local s, e = compute_abs(5.0, 2.0, 3.0)
  assert_eq(s, 7.0, "start = section + take")
  assert_eq(e, 10.0, "end = start + item_length")
end)

test("abs_source_start: zero offset", function()
  local s, e = compute_abs(0, 0, 10.0)
  assert_eq(s, 0, "start")
  assert_eq(e, 10.0, "end")
end)

----------------------------------------------------------------------
-- ext pipeline: unified Branch D logic
----------------------------------------------------------------------
-- Simulates Branch D from the refactored ext computation
local function ext_branch_d(params)
  local is_looped = params.is_looped
  local unwrapped = params.unwrapped_start_offset
  local view_start_offset = params.view_start_offset
  local section_offset = params.section_offset
  local source_item_length = params.source_item_length
  local source_length = params.source_length
  local is_loop_src = params.is_loop_src
  local has_section = params.has_section
  local dragging = params.dragging
  local drag_start = params.drag_start
  local drag_end = params.drag_end
  local post_drag_start = params.post_drag_start
  local post_drag_end = params.post_drag_end
  local post_drag_offset = params.post_drag_offset

  -- Compute so (inline compute_so logic)
  local function compute_so()
    local so = view_start_offset
    if source_length > 0 and is_loop_src and so >= source_length then so = so % source_length end
    if is_loop_src and has_section then so = so + section_offset end
    return so
  end

  local abs_s
  if is_looped then
    abs_s = (unwrapped or view_start_offset) + section_offset
  else
    abs_s = compute_so()
  end
  local abs_e = abs_s + source_item_length

  if dragging and drag_start then
    abs_s = drag_start
    abs_e = drag_end
  elseif post_drag_start ~= nil then
    local offset_changed = post_drag_offset ~= nil
        and math.abs(view_start_offset - post_drag_offset) > 0.001
    if not offset_changed
        and math.abs(source_item_length - (post_drag_end - post_drag_start)) < 0.001 then
      abs_s = post_drag_start
      abs_e = post_drag_end
    end
  end

  local ext_start = math.min(abs_s, 0)
  local ext_end = math.max(abs_e, source_length)
  return ext_start, ext_end
end

-- Default non-looped, no drag, no post-drag
test("ext Branch D: default non-looped", function()
  local es, ee = ext_branch_d({
    is_looped = false, view_start_offset = 1.0, section_offset = 0,
    source_item_length = 3.0, source_length = 10.0,
    is_loop_src = false, has_section = false,
  })
  assert_eq(es, 0, "ext_start clamped to 0")
  assert_eq(ee, 10.0, "ext_end = source_length")
end)

-- Non-looped with negative offset (dragged past left edge)
test("ext Branch D: negative offset", function()
  local es, ee = ext_branch_d({
    is_looped = false, view_start_offset = -2.0, section_offset = 0,
    source_item_length = 3.0, source_length = 10.0,
    is_loop_src = false, has_section = false,
  })
  assert_eq(es, -2.0, "ext_start follows negative offset")
  assert_eq(ee, 10.0, "ext_end = source_length")
end)

-- Looped with unwrapped offset
test("ext Branch D: looped with unwrapped", function()
  local es, ee = ext_branch_d({
    is_looped = true, unwrapped_start_offset = 8.0,
    view_start_offset = 2.0, section_offset = 1.0,
    source_item_length = 5.0, source_length = 10.0,
    is_loop_src = true, has_section = true,
  })
  -- abs_s = 8.0 + 1.0 = 9.0, abs_e = 14.0
  assert_eq(es, 0, "ext_start clamped to 0")
  assert_eq(ee, 14.0, "ext_end = max(14, 10)")
end)

-- During drag
test("ext Branch D: during drag", function()
  local es, ee = ext_branch_d({
    is_looped = false, view_start_offset = 1.0, section_offset = 0,
    source_item_length = 3.0, source_length = 10.0,
    is_loop_src = false, has_section = false,
    dragging = true, drag_start = -1.0, drag_end = 2.0,
  })
  assert_eq(es, -1.0, "ext_start follows drag")
  assert_eq(ee, 10.0, "ext_end = max(2, 10)")
end)

-- Post-drag valid
test("ext Branch D: post-drag valid", function()
  local es, ee = ext_branch_d({
    is_looped = false, view_start_offset = 1.0, section_offset = 0,
    source_item_length = 5.0, source_length = 10.0,
    is_loop_src = false, has_section = false,
    post_drag_start = -2.0, post_drag_end = 3.0, post_drag_offset = 1.0,
  })
  assert_eq(es, -2.0, "ext_start from post-drag")
  assert_eq(ee, 10.0, "ext_end = max(3, 10)")
end)

-- Post-drag invalidated by offset change (undo)
test("ext Branch D: post-drag invalidated by offset change", function()
  local es, ee = ext_branch_d({
    is_looped = false, view_start_offset = 5.0, section_offset = 0,
    source_item_length = 3.0, source_length = 10.0,
    is_loop_src = false, has_section = false,
    post_drag_start = -2.0, post_drag_end = 1.0, post_drag_offset = 1.0,
  })
  -- offset_changed = |5.0 - 1.0| > 0.001 → true, so post-drag discarded
  -- Falls through to default: abs_s = 5.0, abs_e = 8.0
  assert_eq(es, 0, "ext_start = 0 (default)")
  assert_eq(ee, 10.0, "ext_end = source_length (default)")
end)

-- Post-drag invalidated by length mismatch (quantize)
test("ext Branch D: post-drag invalidated by length mismatch", function()
  local es, ee = ext_branch_d({
    is_looped = false, view_start_offset = 1.0, section_offset = 0,
    source_item_length = 6.0, source_length = 10.0,
    is_loop_src = false, has_section = false,
    post_drag_start = -2.0, post_drag_end = 1.0, post_drag_offset = 1.0,
  })
  -- length mismatch: |6.0 - (1.0 - (-2.0))| = |6.0 - 3.0| = 3.0 > 0.001
  -- Falls through to default: abs_s = 1.0, abs_e = 7.0
  assert_eq(es, 0, "ext_start = 0 (default)")
  assert_eq(ee, 10.0, "ext_end = source_length (default)")
end)

-- Looped without unwrapped (nil fallback)
test("ext Branch D: looped without unwrapped", function()
  local es, ee = ext_branch_d({
    is_looped = true, unwrapped_start_offset = nil,
    view_start_offset = 3.0, section_offset = 2.0,
    source_item_length = 8.0, source_length = 10.0,
    is_loop_src = true, has_section = true,
  })
  -- abs_s = (nil or 3.0) + 2.0 = 5.0, abs_e = 13.0
  assert_eq(es, 0, "ext_start = 0")
  assert_eq(ee, 13.0, "ext_end = max(13, 10)")
end)

----------------------------------------------------------------------
-- View offset pipeline: unified Branch 3
----------------------------------------------------------------------
local function view_offset_branch3(params)
  local is_looped = params.is_looped
  local unwrapped = params.unwrapped_start_offset
  local view_start_offset = params.view_start_offset
  local section_offset = params.section_offset
  local source_item_length = params.source_item_length
  local source_length = params.source_length
  local is_loop_src = params.is_loop_src
  local has_section = params.has_section
  local dragging = params.dragging
  local drag_start = params.drag_start
  local drag_end = params.drag_end
  local post_drag_start = params.post_drag_start
  local post_drag_end = params.post_drag_end

  local function compute_so()
    local so = view_start_offset
    if source_length > 0 and is_loop_src and so >= source_length then so = so % source_length end
    if is_loop_src and has_section then so = so + section_offset end
    return so
  end

  local view_offset, view_item_length
  if is_looped then
    view_offset = (unwrapped or view_start_offset) + section_offset
  else
    view_offset = compute_so()
  end
  view_item_length = source_item_length

  if dragging and drag_start ~= nil then
    view_offset = drag_start
    view_item_length = drag_end - drag_start
  elseif post_drag_start ~= nil then
    view_offset = post_drag_start
    view_item_length = post_drag_end - post_drag_start
  end

  return view_offset, view_item_length
end

test("view_offset Branch 3: default non-looped", function()
  local vo, vil = view_offset_branch3({
    is_looped = false, view_start_offset = 2.0, section_offset = 0,
    source_item_length = 3.0, source_length = 10.0,
    is_loop_src = false, has_section = false,
  })
  assert_eq(vo, 2.0, "view_offset")
  assert_eq(vil, 3.0, "view_item_length")
end)

test("view_offset Branch 3: looped with unwrapped", function()
  local vo, vil = view_offset_branch3({
    is_looped = true, unwrapped_start_offset = 8.0,
    view_start_offset = 2.0, section_offset = 1.0,
    source_item_length = 5.0, source_length = 10.0,
    is_loop_src = true, has_section = true,
  })
  assert_eq(vo, 9.0, "view_offset = unwrapped + section")
  assert_eq(vil, 5.0, "view_item_length = source_item_length")
end)

test("view_offset Branch 3: drag overrides", function()
  local vo, vil = view_offset_branch3({
    is_looped = false, view_start_offset = 2.0, section_offset = 0,
    source_item_length = 3.0, source_length = 10.0,
    is_loop_src = false, has_section = false,
    dragging = true, drag_start = -1.0, drag_end = 4.0,
  })
  assert_eq(vo, -1.0, "view_offset from drag")
  assert_eq(vil, 5.0, "view_item_length from drag")
end)

test("view_offset Branch 3: post-drag overrides", function()
  local vo, vil = view_offset_branch3({
    is_looped = false, view_start_offset = 2.0, section_offset = 0,
    source_item_length = 3.0, source_length = 10.0,
    is_loop_src = false, has_section = false,
    post_drag_start = -2.0, post_drag_end = 1.0,
  })
  assert_eq(vo, -2.0, "view_offset from post-drag")
  assert_eq(vil, 3.0, "view_item_length from post-drag")
end)

----------------------------------------------------------------------
-- Render start pipeline: unified Branch 3
----------------------------------------------------------------------
local function render_branch3(params)
  local is_looped = params.is_looped
  local view_start_offset = params.view_start_offset
  local section_offset = params.section_offset
  local source_item_length = params.source_item_length
  local source_length = params.source_length
  local is_loop_src = params.is_loop_src
  local has_section = params.has_section
  local dragging = params.dragging
  local drag_start = params.drag_start
  local drag_end = params.drag_end
  local post_drag_start = params.post_drag_start
  local post_drag_end = params.post_drag_end
  local ext_start = params.ext_start
  local ext_end = params.ext_end

  local function compute_so()
    local so = view_start_offset
    if source_length > 0 and is_loop_src and so >= source_length then so = so % source_length end
    if is_loop_src and has_section then so = so + section_offset end
    return so
  end

  local render_start, render_end
  if dragging then
    render_start = drag_start
    render_end = drag_end
  elseif post_drag_start ~= nil then
    render_start = post_drag_start
    render_end = post_drag_end
  elseif is_looped then
    render_start = ext_start
    render_end = ext_end
  else
    local so = compute_so()
    render_start = so
    render_end = so + source_item_length
  end
  return render_start, render_end
end

test("render Branch 3: default non-looped", function()
  local rs, re = render_branch3({
    is_looped = false, view_start_offset = 2.0, section_offset = 0,
    source_item_length = 3.0, source_length = 10.0,
    is_loop_src = false, has_section = false,
  })
  assert_eq(rs, 2.0, "render_start")
  assert_eq(re, 5.0, "render_end")
end)

test("render Branch 3: looped uses ext", function()
  local rs, re = render_branch3({
    is_looped = true, view_start_offset = 2.0, section_offset = 1.0,
    source_item_length = 5.0, source_length = 10.0,
    is_loop_src = true, has_section = true,
    ext_start = -1.0, ext_end = 14.0,
  })
  assert_eq(rs, -1.0, "render_start = ext_start")
  assert_eq(re, 14.0, "render_end = ext_end")
end)

test("render Branch 3: drag overrides looped", function()
  local rs, re = render_branch3({
    is_looped = true, view_start_offset = 2.0, section_offset = 1.0,
    source_item_length = 5.0, source_length = 10.0,
    is_loop_src = true, has_section = true,
    ext_start = -1.0, ext_end = 14.0,
    dragging = true, drag_start = -3.0, drag_end = 2.0,
  })
  assert_eq(rs, -3.0, "render_start from drag, not ext")
  assert_eq(re, 2.0, "render_end from drag, not ext")
end)

test("render Branch 3: post-drag overrides looped", function()
  local rs, re = render_branch3({
    is_looped = true, view_start_offset = 2.0, section_offset = 1.0,
    source_item_length = 5.0, source_length = 10.0,
    is_loop_src = true, has_section = true,
    ext_start = -1.0, ext_end = 14.0,
    post_drag_start = -2.0, post_drag_end = 3.0,
  })
  assert_eq(rs, -2.0, "render_start from post-drag")
  assert_eq(re, 3.0, "render_end from post-drag")
end)

----------------------------------------------------------------------
-- Cross-pipeline consistency: ext, view_offset, render_start agree
----------------------------------------------------------------------
test("consistency: all pipelines agree for simple non-looped", function()
  local params = {
    is_looped = false, view_start_offset = 2.0, section_offset = 0,
    source_item_length = 3.0, source_length = 10.0,
    is_loop_src = false, has_section = false,
  }
  local es, ee = ext_branch_d(params)
  local vo, vil = view_offset_branch3(params)
  local rs, re = render_branch3({
    is_looped = false, view_start_offset = 2.0, section_offset = 0,
    source_item_length = 3.0, source_length = 10.0,
    is_loop_src = false, has_section = false,
    ext_start = es, ext_end = ee,
  })
  -- view_offset and render_start should match
  assert_eq(vo, rs, "view_offset == render_start")
  assert_eq(vo + vil, re, "view_offset + view_item_length == render_end")
  -- ext should contain the render range
  assert_true(es <= rs, "ext_start <= render_start")
  assert_true(ee >= re, "ext_end >= render_end")
end)

test("consistency: all pipelines agree for looped", function()
  local params_ext = {
    is_looped = true, unwrapped_start_offset = 12.0,
    view_start_offset = 2.0, section_offset = 1.0,
    source_item_length = 8.0, source_length = 10.0,
    is_loop_src = true, has_section = true,
  }
  local es, ee = ext_branch_d(params_ext)
  -- ext: abs_s = 12 + 1 = 13, abs_e = 21, ext_start = 0, ext_end = 21

  local params_vo = {
    is_looped = true, unwrapped_start_offset = 12.0,
    view_start_offset = 2.0, section_offset = 1.0,
    source_item_length = 8.0, source_length = 10.0,
    is_loop_src = true, has_section = true,
  }
  local vo, vil = view_offset_branch3(params_vo)
  -- vo = 12 + 1 = 13, vil = 8

  local params_rs = {
    is_looped = true, view_start_offset = 2.0, section_offset = 1.0,
    source_item_length = 8.0, source_length = 10.0,
    is_loop_src = true, has_section = true,
    ext_start = es, ext_end = ee,
  }
  local rs, re = render_branch3(params_rs)
  -- looped: rs = ext_start, re = ext_end

  -- For looped items, render uses ext (full extended range)
  assert_eq(rs, es, "render_start == ext_start for looped")
  assert_eq(re, ee, "render_end == ext_end for looped")
  -- ext should still contain view_offset range
  assert_true(es <= vo, "ext_start <= view_offset")
  assert_true(ee >= vo + vil, "ext_end >= view_offset + view_item_length")
end)

test("consistency: drag state overrides all pipelines uniformly", function()
  local drag_params = {
    is_looped = false, view_start_offset = 2.0, section_offset = 0,
    source_item_length = 5.0, source_length = 10.0,
    is_loop_src = false, has_section = false,
    dragging = true, drag_start = -1.0, drag_end = 4.0,
  }
  local es, ee = ext_branch_d(drag_params)
  local vo, vil = view_offset_branch3(drag_params)
  local rs, re = render_branch3({
    is_looped = false, view_start_offset = 2.0, section_offset = 0,
    source_item_length = 5.0, source_length = 10.0,
    is_loop_src = false, has_section = false,
    dragging = true, drag_start = -1.0, drag_end = 4.0,
    ext_start = es, ext_end = ee,
  })
  -- During drag, view_offset and render_start should both use drag coordinates
  assert_eq(vo, -1.0, "view_offset = drag_start")
  assert_eq(rs, -1.0, "render_start = drag_start")
  assert_eq(re, 4.0, "render_end = drag_end")
  -- ext contains drag range
  assert_true(es <= -1.0, "ext_start <= drag_start")
  assert_true(ee >= 4.0, "ext_end >= drag_end")
end)
