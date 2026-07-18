ALTER TABLE farm_directories
ADD COLUMN security_generation INTEGER NOT NULL DEFAULT 1;

CREATE INDEX farm_directories_security_generation_idx
ON farm_directories(id, security_generation);
