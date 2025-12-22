#!/usr/bin/env lua
-- Test runner for NVSD_ItemView
-- Run with: lua tests/run_tests.lua

package.path = package.path .. ";tests/?.lua;?.lua"

local lu = require("luaunit")

-- Load test files
require("nvsd_itemview_test")

-- Run tests
os.exit(lu.LuaUnit.run())
