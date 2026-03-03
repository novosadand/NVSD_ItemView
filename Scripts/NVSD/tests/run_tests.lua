-- Minimal test runner for NVSD_ItemView coordinate pipeline tests
-- Usage: lua5.4 tests/run_tests.lua  (from Scripts/NVSD/ directory)

local passed = 0
local failed = 0
local errors = {}

function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
    errors[#errors + 1] = { name = name, err = err }
  end
end

function assert_eq(a, b, msg)
  if type(a) == "number" and type(b) == "number" then
    if math.abs(a - b) > 0.0001 then
      error(string.format("%s: expected %g, got %g", msg or "assert_eq", b, a))
    end
  elseif a ~= b then
    error(string.format("%s: expected %s, got %s", msg or "assert_eq", tostring(b), tostring(a)))
  end
end

function assert_true(v, msg)
  if not v then error(msg or "expected true") end
end

-- Load test files
dofile("tests/test_coordinate_pipeline.lua")

-- Report
print(string.format("\n%d passed, %d failed", passed, failed))
for _, e in ipairs(errors) do
  print(string.format("  FAIL: %s\n        %s", e.name, e.err))
end

os.exit(failed > 0 and 1 or 0)
