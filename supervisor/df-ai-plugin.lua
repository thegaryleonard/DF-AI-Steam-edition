local _ENV = mkmodule('plugins.df-ai')
-- functions from df-ai.plug.dll:
--   planned_room_at(x1, y1, x2, y2, z) -> description of a df-ai planned room
--     overlapping the box, or ''
--   set_guard_posts('x,y,z;x,y,z') -> number of posts: where squads stand
--     guard in the months they don't train
return _ENV
