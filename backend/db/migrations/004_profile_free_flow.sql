-- Each station's free-flow speed: how fast traffic moves there when the road
-- is empty. Baselines add only the delay beyond it to the routing service's
-- own no-traffic time. 0 means unknown; rebuild the profiles to populate it.
ALTER TABLE baseline_profiles
  ADD COLUMN free_flow_mph real NOT NULL DEFAULT 0
  CHECK (free_flow_mph >= 0);
