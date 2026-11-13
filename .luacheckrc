std = "lua51"
max_line_length = false
-- WoW exposes its API as globals; only check syntax, unused/shadowed locals, etc.
ignore = {
    "11.",  -- setting/accessing/mutating globals
    "212",  -- unused argument
}
exclude_files = { ".release/" }
