-- The alert rules' tables, for these tests: a copy of the ones the chart loads
-- (external-security.zindello.com.au, deploy/alerts/schema.sql, and its
-- docs/alert-rules.md, "The tables"). Keep the two the same.

CREATE TABLE IF NOT EXISTS alert_rules (
  user_id     INT UNSIGNED NOT NULL,
  monitor_id  INT UNSIGNED NOT NULL,
  alerts      BOOLEAN NOT NULL,
  labels      JSON NOT NULL,
  updated_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (user_id, monitor_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS alert_users (
  user_id     INT UNSIGNED NOT NULL PRIMARY KEY,
  alerts      BOOLEAN NOT NULL,
  updated_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS alert_phones (
  token_hash   CHAR(64) NOT NULL PRIMARY KEY,
  username     VARCHAR(64) NULL,
  platform     VARCHAR(16) NOT NULL,
  app_version  VARCHAR(32) NOT NULL,
  profile      VARCHAR(64) NULL,
  first_seen   DATETIME NULL,
  last_seen    DATETIME NULL,
  last_push    DATETIME NULL,
  remove       BOOLEAN NOT NULL DEFAULT FALSE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Live detection's record of what raised or held each alarm: a copy of the chart's
-- (external-security.zindello.com.au, deploy/live/schema.sql, detector_alarms), which following
-- an event reads. Keep the two the same.
CREATE TABLE IF NOT EXISTS detector_alarms (
  monitor_id       INT UNSIGNED NOT NULL,
  raised_at        DATETIME(6) NOT NULL,
  label            VARCHAR(32) NOT NULL,
  first_seen       DATETIME(6) NOT NULL,
  last_seen        DATETIME(6) NOT NULL,
  best_confidence  DECIMAL(3,2) NOT NULL,
  raised           BOOLEAN NOT NULL,
  picture          VARCHAR(128) NULL,
  PRIMARY KEY (monitor_id, raised_at, label),
  KEY by_last_seen (monitor_id, last_seen)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
