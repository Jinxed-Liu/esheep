ALTER TABLE devices
ADD COLUMN tmr_data_protocol_version INTEGER NOT NULL DEFAULT 0
CHECK (tmr_data_protocol_version >= 0);
