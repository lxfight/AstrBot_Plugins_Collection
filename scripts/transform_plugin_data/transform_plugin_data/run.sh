#!/usr/bin/env bash

echo "开始转换插件数据格式..."

# 使用jq转换数据格式，增加容错处理，并过滤掉404的仓库
existing_cache_file="existing_cache.json"
cleanup_existing_cache="false"

# 如果没有历史缓存，为jq提供一个空对象以便统一逻辑
if [ ! -f "$existing_cache_file" ]; then
  existing_cache_file=$(mktemp)
  if [ -f "plugin_cache_original.json" ]; then
    cp plugin_cache_original.json "$existing_cache_file"
  else
    echo "{}" > "$existing_cache_file"
  fi
  cleanup_existing_cache="true"
fi

jq --slurpfile repo_info repo_info.json --slurpfile existing_cache "$existing_cache_file" '
($repo_info | if length > 0 then .[0] else {} end) as $repos |
($existing_cache | if length > 0 then .[0] else {} end) as $raw_cache |
(if ($raw_cache | type) == "object" and ($raw_cache | has("data")) and (($raw_cache.data | type) == "object") then $raw_cache.data
 elif ($raw_cache | type) == "object" then $raw_cache
 else {}
 end) as $cache |
to_entries |
map(
  . as $plugin |
  ($repos[$plugin.value.repo] // null) as $repo_entry |
  ($cache[$plugin.key] // {}) as $cache_entry |
  ($repo_entry | if . then .status else "" end) as $repo_status |
  # 403 等非 success 且没有缓存的仓库直接丢弃，保持缓存一致性
  if ($repo_entry and ($repo_status == "deleted" or ($repo_status != "success" and ($cache_entry | length) == 0))) then
    empty
  else
  ($repo_entry | if . then .version else "" end) as $repo_version |
  ($cache_entry.version // "") as $cache_version |
  ($repo_entry | if . then .stars else null end) as $repo_stars |
  ($cache_entry.stars // 0) as $cache_stars |
  ($repo_entry | if . then .updated_at else "" end) as $repo_updated |
  ($cache_entry.updated_at // "") as $cache_updated |
  ($repo_entry | if . then .logo else "" end) as $repo_logo |
  ($cache_entry.logo // "") as $cache_logo |
  (if ($repo_version // "") != "" then $repo_version
   elif ($cache_version // "") != "" then $cache_version
   else "1.0.0"
   end) as $final_version |
  (if ($repo_status == "success") and ($repo_stars != null) then $repo_stars else $cache_stars end) as $final_stars |
  (if ($repo_updated // "") != "" then $repo_updated
   elif ($cache_updated // "") != "" then $cache_updated
   else ""
   end) as $final_updated |
  (if ($repo_logo // "") != "" then $repo_logo
   elif ($cache_logo // "") != "" then $cache_logo
   else ""
   end) as $final_logo |
  {
    key: $plugin.key,
    value:
      (
        $plugin.value + {
          # 保持原有字段
          desc: $plugin.value.desc,
          author: $plugin.value.author,
          repo: $plugin.value.repo,
          tags: ($plugin.value.tags // [])
        }
        + (if $plugin.value.social_link then { social_link: $plugin.value.social_link } else {} end)
        + {
          stars: ($final_stars // 0),
          version: $final_version
        }
        + (if ($final_updated // "") != "" then { updated_at: $final_updated } else {} end)
        + (if ($final_logo // "") != "" then { logo: $final_logo } else {} end)
      )
  }
  end
) | from_entries' original_plugins.json > temp_plugin_cache_original.json

if [ "$cleanup_existing_cache" = "true" ]; then
  rm -f "$existing_cache_file"
fi

# 格式化JSON使其更易读
jq . temp_plugin_cache_original.json > plugin_cache_original.json

echo "✅ 数据转换完成"

# 显示转换统计
original_count=$(jq 'keys | length' original_plugins.json)
new_count=$(jq 'keys | length' plugin_cache_original.json)
removed_count=$((original_count - new_count))

# 统计不同状态的仓库
success_repos=$(jq '[.[] | select(.status == "success")] | length' repo_info.json)
cached_repos=$(jq '[.[] | select(.status == "cached")] | length' repo_info.json)
redirected_repos=$(jq '[.[] | select(.status == "redirected")] | length' repo_info.json)
deleted_repos=$(jq '[.[] | select(.status == "deleted")] | length' repo_info.json)
failed_repos=$(jq '[.[] | select(.status != "success" and .status != "cached" and .status != "redirected" and .status != "deleted")] | length' repo_info.json)

echo ""
echo "📊 转换统计:"
echo "  插件数量变化: $original_count -> $new_count"
if [ $removed_count -gt 0 ]; then
  echo "  🗑️  已移除: $removed_count 个失效插件"
fi
echo "  ✅ 实时数据: $success_repos 个仓库"
echo "  🔄 缓存数据: $cached_repos 个仓库"
echo "  🔄 重定向: $redirected_repos 个仓库"
echo "  🗑️  已删除(已移除): $deleted_repos 个仓库"
echo "  ❌ 网络错误(已保留): $failed_repos 个仓库"

# 列出被移除的仓库
if [ $removed_count -gt 0 ]; then
  echo ""
  echo "🗑️  以下仓库已从缓存中移除:"
  jq -r 'to_entries[] | select(.value.status == "deleted") | "  - " + .key + " (404 Not Found)"' repo_info.json
fi

# 列出网络错误的仓库（保留但使用缓存数据）
if [ "$failed_repos" -gt 0 ]; then
  echo ""
  echo "❌ 网络错误的仓库（已保留，使用缓存数据）:"
  jq -r 'to_entries[] | select(.value.status != "success" and .value.status != "cached" and .value.status != "redirected" and .value.status != "deleted") | "  - " + .key + " (" + .value.status + ")"' repo_info.json
fi

# 列出重定向的仓库（保留但标记）
if [ "$redirected_repos" -gt 0 ]; then
  echo ""
  echo "🔄 发生重定向的仓库列表（已保留）:"
  jq -r 'to_entries[] | select(.value.status == "redirected") | "  - " + .key' repo_info.json
fi


