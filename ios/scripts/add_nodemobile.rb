# ios/scripts/add_nodemobile.rb
#
# 自动给 Runner.xcodeproj 加：
#   1. NodeJSBridge.swift 进 Runner group + Sources build phase
#   2. NodeMobile.xcframework 进 Frameworks group + Frameworks build phase
#   3. NodeMobile.xcframework 进 Embed Frameworks build phase
#
# 关键设计：xcframework **必须** 放在 `ios/Frameworks/` 目录下（项目内）。
# pbxproj 用短路径 `Frameworks/NodeMobile.xcframework`，source_tree = '<group>'。
# 这样无论 xcode 解析从 ios/ 还是 Runner.xcodeproj/ 出发，都能正确找到文件。
#
# 用法（在 ios/ 目录下跑）：
#   bundle exec ruby scripts/add_nodemobile.rb \
#     --xcframework Frameworks/NodeMobile.xcframework
#
# 或在 GitHub Actions workflow 里（`cd ios` 后跑）：
#   - run: |
#       gem install xcodeproj --no-document
#       ruby ios/scripts/add_nodemobile.rb \
#         --xcframework Frameworks/NodeMobile.xcframework

require 'xcodeproj'
require 'optparse'
require 'pathname'

options = {
  xcframework: nil,
  pbxproj: 'Runner.xcodeproj/project.pbxproj',
  # 默认只注册 NodeJSBridge.swift（其它 Swift bridge 在需要时通过
  # --extra-swift 显式传入）
  extra_swift_files: %w[NodeJSBridge.swift],
}

OptionParser.new do |opts|
  opts.on('--xcframework PATH', 'NodeMobile.xcframework 路径（相对 ios/，例如 Frameworks/NodeMobile.xcframework）') do |v|
    options[:xcframework] = v
  end
  opts.on('--pbxproj PATH', 'project.pbxproj 路径（默认 Runner.xcodeproj/project.pbxproj）') do |v|
    options[:pbxproj] = v
  end
  opts.on('--extra-swift x,y,z', Array, '额外的 Swift 文件列表（默认 NodeJSBridge.swift）') do |v|
    options[:extra_swift_files] = v
  end
end.parse!

if options[:xcframework].nil?
  abort("❌ 必须指定 --xcframework 参数")
end

# 校验 xcframework 存在
xcframework_abs = File.expand_path(options[:xcframework], Dir.pwd)
unless Dir.exist?(xcframework_abs)
  abort("❌ 找不到 xcframework: #{xcframework_abs}")
end

# project.pbxproj 文件绝对路径
pbxproj_file = File.expand_path(options[:pbxproj], Dir.pwd)
unless File.exist?(pbxproj_file)
  abort("❌ 找不到 pbxproj: #{pbxproj_file}")
end

# Xcodeproj::Project.open 期望传入**项目目录**（Runner.xcodeproj/），
# 不是 project.pbxproj 文件路径。
# 内部 `initialize_from_file` 会执行 `path + 'project.pbxproj'`，所以
# 如果传了文件路径会变成 `Runner.xcodeproj/project.pbxproj/project.pbxproj`
project_dir = File.dirname(pbxproj_file)

project = Xcodeproj::Project.open(project_dir)
runner_target = project.targets.find { |t| t.name == 'Runner' }
abort('❌ 找不到 Runner target') unless runner_target

# ============================================================
# 1. 加 Swift bridge 文件到 Runner group + Sources
#    （默认 NodeJSBridge.swift，可通过 --extra-swift 添加更多）
# ============================================================

runner_group = project.main_group['Runner']
abort('❌ 找不到 Runner group') unless runner_group

options[:extra_swift_files].each do |bridge_filename|
  next if bridge_filename.nil? || bridge_filename.empty?
  # 跳过不存在的文件（避免 workflow 在开发期没创建该 bridge 时报错）
  #
  # ⚠️ 路径修正：project_dir 是 Runner.xcodeproj/ 目录（如 /path/to/ios/Runner.xcodeproj）
  # bridge 文件在 ios/Runner/ 下（即 project_dir 的**父目录**的 Runner 子目录）
  # 之前用 `File.join(project_dir, 'Runner')` 会拼成 Runner.xcodeproj/Runner/（不存在）
  # 改成 `File.expand_path('Runner', File.dirname(project_dir))` 才对
  runner_dir = File.expand_path('Runner', File.dirname(project_dir))
  bridge_abs = File.expand_path(bridge_filename, runner_dir)
  unless File.exist?(bridge_abs)
    puts "⚠️ 跳过 #{bridge_filename}（文件不存在: #{bridge_abs}）"
    next
  end

  if runner_target.source_build_phase.files_references.any? { |ref| ref&.path == bridge_filename }
    puts "✅ #{bridge_filename} 已在 Runner target 中"
    next
  end

  bridge_ref = runner_group.files.find { |f| f.path == bridge_filename }
  unless bridge_ref
    bridge_ref = runner_group.new_reference(bridge_filename)
    bridge_ref.last_known_file_type = 'sourcecode.swift'
  end
  runner_target.source_build_phase.add_file_reference(bridge_ref, true)
  puts "✅ 已加 #{bridge_filename} 到 Runner target"
end

# ============================================================
# 2. 加 NodeMobile.xcframework 到 Frameworks group + Frameworks build phase
# ============================================================
#
# ⚠️ pbxproj 用**相对路径**且 `source_tree = '<group>'`
# xcframework 必须在 ios/Frameworks/ 下，这样 path 就是 'Frameworks/NodeMobile.xcframework'，
# 短且稳定（无论 Xcode 从哪个 base 解析都能找到）。

framework_relative_path = options[:xcframework]  # 例如 'Frameworks/NodeMobile.xcframework'
framework_basename = File.basename(framework_relative_path)

# Frameworks group（顶层那个）
frameworks_group = project.main_group['Frameworks']
unless frameworks_group
  # 关键：第二个参数是 group 的 path，所以新 group 的 path = 'Frameworks'
  frameworks_group = project.main_group.new_group('Frameworks', 'Frameworks')
end

framework_ref = frameworks_group.files.find { |f| f.path == framework_relative_path || f.name == framework_basename }
unless framework_ref
  # 用相对 path（'Frameworks/NodeMobile.xcframework'）让 xcodeproj 写入 pbxproj
  # source_tree 默认为 '<group>'
  framework_ref = frameworks_group.new_file(framework_relative_path)
  framework_ref.name = framework_basename
  framework_ref.last_known_file_type = 'wrapper.xcframework'
  puts "✅ 已加 #{framework_basename} 到 Frameworks group (path=#{framework_ref.path})"
else
  puts "✅ #{framework_basename} 已在 Frameworks group 中"
end

# Frameworks build phase（link）
unless runner_target.frameworks_build_phase.files_references.include?(framework_ref)
  runner_target.frameworks_build_phase.add_file_reference(framework_ref, true)
  puts "✅ 已 link #{framework_basename}"
else
  puts "✅ #{framework_basename} 已 link"
end

# ============================================================
# 3. 加到 Embed Frameworks build phase
# ============================================================

embed_phase = runner_target.copy_files_build_phases.find { |p| p.name == 'Embed Frameworks' }
unless embed_phase
  # 没有就建一个
  embed_phase = runner_target.new_copy_files_build_phase('Embed Frameworks')
  embed_phase.symbol_dst_subfolder_spec = :frameworks
  puts '✅ 已创建 Embed Frameworks build phase'
end

unless embed_phase.files_references.include?(framework_ref)
  build_file = embed_phase.add_file_reference(framework_ref, true)
  # 设置 embed = true（attributed 里 'CodeSignOnCopy' = YES, 'RemoveHeadersOnCopy' = YES）
  build_file.settings = {
    'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy'],
  }
  puts "✅ 已加 #{framework_basename} 到 Embed Frameworks (CodeSignOnCopy)"
else
  puts "✅ #{framework_basename} 已在 Embed Frameworks"
end

# ============================================================
# 保存
# ============================================================
project.save
puts ''
puts "💾 已保存 #{pbxproj_file}"
puts ''
puts '🔍 最终状态：'
puts "  - Runner target sources: #{runner_target.source_build_phase.files_references.map(&:path).compact.uniq.join(', ')}"
puts "  - Runner target frameworks: #{runner_target.frameworks_build_phase.files_references.map(&:path).compact.uniq.join(', ')}"
embed_phase&.files_references&.each do |f|
  puts "  - Embed: #{f.path}"
end
