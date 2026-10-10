#!/bin/bash

WORKFLOW_FILE=".github/workflows/run_first.yml"
LOG_FILE="walking_cron_change.log"

# 读取 walking.yml 中当前的 cron 表达式（分 时 * * *）
function read_walking_cron {
  grep -m1 "cron:" "$WORKFLOW_FILE" | awk '{print substr($0, index($0,$3))}' | tr -d "'" | xargs
}

# 根据当前 cron 计算新 cron，逼近北京时间8点
# 规则：晚于8点 → 提前8分钟；早于8点 → 推迟1分钟
function calc_next_cron {
  local cron_str=$1

  # 校验格式
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

  # 北京时间8点 = UTC 0点
  # UTC 22:00 ~ 23:59 → 北京时间 6:00 ~ 7:59，属于"早于8点"
  if [ "$cron_hour" -ge 22 ]; then
    new_minute=$((cron_minute + 1))
    new_hour=$cron_hour
    if [ $new_minute -ge 60 ]; then
      new_minute=0
      new_hour=$((new_hour + 1))
      if [ $new_hour -ge 24 ]; then
        new_hour=0
      fi
    fi
    reason="早于北京时间 8 点，推迟 1 分钟"
  else
    new_minute=$((cron_minute - 8))
    new_hour=$cron_hour
    if [ $new_minute -lt 0 ]; then
      new_minute=$((new_minute + 60))
      new_hour=$((new_hour - 1))
      if [ $new_hour -lt 0 ]; then
        new_hour=23
      fi
    fi
    reason="晚于或等于北京时间 8 点，提前 8 分钟"
  fi

  new_minute=$(printf "%02d" $new_minute)
  new_hour=$(printf "%02d" $new_hour)

  echo "$reason" >&2
  echo "$new_minute $new_hour * * *"
}

# 将新的 cron 写回 walking.yml
function update_walking_cron {
  local new_cron=$1
  sed -i "s|cron: '[^']*'|cron: '$new_cron'|" "$WORKFLOW_FILE"
}

# 主入口
function adjust_walking_cron {
  local event_name=$1

  if [ ! -f "$WORKFLOW_FILE" ]; then
    echo "未找到 $WORKFLOW_FILE"
    exit 1
  fi

  local current_cron
  current_cron=$(read_walking_cron)
  echo "当前 cron: [$current_cron]"

  local new_cron
  if ! new_cron=$(calc_next_cron "$current_cron"); then
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
    echo "current cron (UTC): $current_cron"
    echo "next cron (UTC):    $new_cron"
  } > "$LOG_FILE"
}
