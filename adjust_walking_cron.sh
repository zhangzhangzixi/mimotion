#!/bin/bash

WORKFLOW_FILE=".github/workflows/run_first.yml"
LOG_FILE="walking_cron_change.log"

# 读取 walking.yml 中当前的 cron 表达式（分 时 * * *）
function read_walking_cron {
  grep -m1 "cron:" "$WORKFLOW_FILE" | awk '{print substr($0, index($0,$3))}' | tr -d "'" | xargs
}

# 获取 walking 实际运行时间（北京时间的小时和分钟）
# 参数：run_started_at ISO8601 字符串（可为空）
# 输出："<bj_hour> <bj_minute>"
function get_actual_bj_time {
  local run_started_at=$1
  local utc_hour
  local utc_minute

  if [ -n "$run_started_at" ] && [ "$run_started_at" != "null" ]; then
    utc_hour=$(date -d "$run_started_at" -u '+%H')
    utc_minute=$(date -d "$run_started_at" -u '+%M')
  else
    # 手动触发等场景没有 workflow_run 信息，退化为当前时间
    utc_hour=$(TZ=UTC date '+%H')
    utc_minute=$(TZ=UTC date '+%M')
  fi

  utc_hour=$((10#$utc_hour))
  utc_minute=$((10#$utc_minute))

  # 北京时间 = UTC + 8（无夏令时）
  local bj_hour=$(( (utc_hour + 8) % 24 ))
  local bj_minute=$utc_minute

  echo "$bj_hour $bj_minute"
}

# 根据 walking 实际运行时间计算新 cron
# 参数：cron_str  actual_bj_hour  actual_bj_minute
function calc_next_cron {
  local cron_str=$1
  local actual_bj_hour=$2
  local actual_bj_minute=$3

  if ! echo "$cron_str" | grep -Eq '^[0-9]{1,2} [0-9]{1,2} \* \* \*$'; then
    echo "cron 格式不正确: [$cron_str]" >&2
    return 1
  fi

  local cron_minute
  local cron_hour
  cron_minute=$(echo "$cron_str" | awk '{print $1}')
  cron_hour=$(echo "$cron_str" | awk '{print $2}')
  cron_minute=$((10#$cron_minute))
  cron_hour=$((10#$cron_hour))

  local new_minute
  local new_hour
  local reason

  # 实际运行时间（北京时间）转成分钟数，与 8:00（480）比较
  local actual_total=$((actual_bj_hour * 60 + actual_bj_minute))
  local target_total=$((8 * 60))

  if [ $actual_total -lt $target_total ]; then
    # 实际早于 8 点：推迟 1 分钟
    new_minute=$((cron_minute + 1))
    new_hour=$cron_hour
    if [ $new_minute -ge 60 ]; then
      new_minute=0
      new_hour=$((new_hour + 1))
      if [ $new_hour -ge 24 ]; then
        new_hour=0
      fi
    fi
    reason="实际运行早于北京时间 8 点，推迟 1 分钟"
  else
    # 实际晚于或等于 8 点：提前 8 分钟
    new_minute=$((cron_minute - 8))
    new_hour=$cron_hour
    if [ $new_minute -lt 0 ]; then
      new_minute=$((new_minute + 60))
      new_hour=$((new_hour - 1))
      if [ $new_hour -lt 0 ]; then
        new_hour=23
      fi
    fi
    reason="实际运行晚于或等于北京时间 8 点，提前 8 分钟"
  fi

  new_minute=$(printf "%02d" $new_minute)
  new_hour=$(printf "%02d" $new_hour)

  echo "$reason" >&2
  echo "$new_minute $new_hour * * *"
}

# 将新 cron 写回 walking.yml
function update_walking_cron {
  local new_cron=$1
  sed -i "s|cron: '[^']*'|cron: '$new_cron'|" "$WORKFLOW_FILE"
}

# 主入口
function adjust_walking_cron {
  local event_name=$1
  local run_started_at=$2

  if [ ! -f "$WORKFLOW_FILE" ]; then
    echo "未找到 $WORKFLOW_FILE"
    exit 1
  fi

  local current_cron
  current_cron=$(read_walking_cron)
  echo "当前 cron: [$current_cron]"

  local actual_time
  actual_time=$(get_actual_bj_time "$run_started_at")
  local actual_bj_hour
  local actual_bj_minute
  actual_bj_hour=$(echo "$actual_time" | awk '{print $1}')
  actual_bj_minute=$(echo "$actual_time" | awk '{print $2}')
  echo "walking 实际运行时间（北京时间）: $(printf "%02d:%02d" $actual_bj_hour $actual_bj_minute)"

  local new_cron
  if ! new_cron=$(calc_next_cron "$current_cron" "$actual_bj_hour" "$actual_bj_minute"); then
    echo "计算新 cron 失败，终止"
    exit 1
  fi
  echo "新 cron: $new_cron"

  update_walking_cron "$new_cron"

  local updated_cron
  updated_cron=$(read_walking_cron)
  echo "更新后 cron: [$updated_cron]"

  {
    echo "trigger by: ${event_name}"
    echo "current system time:"
    TZ='UTC' date "+%y-%m-%d %H:%M:%S" | xargs -I {} echo "UTC: {}"
    TZ='Asia/Shanghai' date "+%y-%m-%d %H:%M:%S" | xargs -I {} echo "北京时间: {}"
    echo "walking run_started_at (UTC): ${run_started_at:-N/A}"
    echo "walking 实际运行时间(北京时间): $(printf "%02d:%02d" $actual_bj_hour $actual_bj_minute)"
    echo "current cron (UTC): $current_cron"
    echo "next cron (UTC):    $new_cron"
  } > "$LOG_FILE"
}
