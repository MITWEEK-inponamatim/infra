create schema if not exists langgraph;
revoke all on schema langgraph from public, anon, authenticated;
grant usage, create on schema langgraph to postgres, service_role;
alter default privileges for role service_role in schema langgraph
  grant all on tables to service_role;
alter default privileges for role service_role in schema langgraph
  grant all on sequences to service_role;
