create index icloud_capability_user_idx
  on public.icloud_capability_certificates (user_id);

create index icloud_capability_device_idx
  on public.icloud_capability_certificates (device_id);
