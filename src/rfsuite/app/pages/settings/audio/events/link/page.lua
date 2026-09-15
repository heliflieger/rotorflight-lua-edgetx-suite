-- One of the pages under Settings > Audio > Events. category_page.lua beside them builds all
-- of them; what this file contributes is the name of its category.
local CategoryPage = assert(loadScript("/SCRIPTS/TOOLS/rfsuite-core/app/pages/settings/audio/events/category_page.lua", "t"))()

return CategoryPage.new("link")
