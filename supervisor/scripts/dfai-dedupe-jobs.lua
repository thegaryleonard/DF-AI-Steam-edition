-- aitest-dedupe-jobs: remove duplicate unclaimed jobs (same type + same tile),
-- keeping one. Fixes the 368k SmoothWall/SmoothFloor pile-up df-ai caused.
-- usage: aitest-dedupe-jobs [max_removals]
local max = tonumber(({...})[1]) or 100000
local types = {
  [df.job_type.SmoothWall] = true, [df.job_type.SmoothFloor] = true,
  [df.job_type.DetailWall] = true, [df.job_type.DetailFloor] = true,
  [df.job_type.GatherPlants] = true,
}
local seen, victims, total = {}, {}, 0
local l = df.global.world.jobs.list.next
while l do
  local j = l.item
  if j and types[j.job_type] then
    total = total + 1
    local k = j.job_type .. ':' .. j.pos.x .. ',' .. j.pos.y .. ',' .. j.pos.z
    if seen[k] or false then
      if not dfhack.job.getWorker(j) and #victims < max then victims[#victims + 1] = j end
    else
      seen[k] = true
    end
  end
  l = l.next
end
local uniq = 0
for _ in pairs(seen) do uniq = uniq + 1 end
local removed = 0
for _, j in ipairs(victims) do
  if dfhack.job.removeJob(j) then removed = removed + 1 end
end
print(('matching jobs %d, unique type+tile %d, removed %d'):format(total, uniq, removed))
