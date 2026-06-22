# ios/scripts/add_nodemobile.rb
#
# 自动给 Runner.xcodeproj 加：
#   1. NodeJSBridge.swift 进 Runner group + Sources build phase
#   2. NodeMobile.xcframework 进 Frameworks group + Frameworks build phase
#   3. NodeMobile.xcframework 进 Embed Frameworks build phase
#
# 用法（在 iOS 端目录跑）：
#   bundle exec ruby scripts/add_nodemobile.rb \
#     --xcframework ../build/ios/Frameworks/NodeMobile.xcframework
#
# 或在 GitHub Actions workflow 里：
#   - run: |
#       gem install xcodeproj --no-document
#       ruby ios/scripts/add_nodemobile.rb \
#         --xcframework build/ios/Frameworks/NodeMobile.xcframework

require 'xcodeproj'
require 'optparse'
require 'pathname'

options = {
  xcframework: nil,
  pbxproj: 'Runner.xcodeproj/project.pbxproj',
}

OptionParser.new do |opts|
  opts.on('--xcframework PATH', 'NodeMobile.xcframework 路径（相对 ios/）') do |v|
    options[:xcframework] = v
  end
  opts.on('--pbxproj PATH', 'project.pbxproj 路径（默认 Runner.xcodeproj/project.pbxproj）') do |v|
    options[:pbxproj] = v
  end
end.parse!

if options[:xcframework].nil?
  abort("❌ 必须指定 --xcframework 参数")
end

# 把传入的 xcframework 路径转成绝对路径
# 用 `Dir.pwd`（当前工作目录）做 base，因为：
#   - workflow 步骤 `cd ios` 后，参数会被解析为相对 ios/
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

# ⚠️ 关键：`Xcodeproj::Project.open` 不会改 Dir.pwd，
# 但内部创建 PBXFileReference 时会假设 path 相对 project_dir。
# 所以我们必须确保后续 add_file 时 path 是相对 project_dir 的。
project = Xcodeproj::Project.open(project_dir)
runner_target = project.targets.find { |t| t.name == 'Runner' }
abort('❌ 找不到 Runner target') unless runner_target

# ============================================================
# 1. 加 NodeJSBridge.swift 到 Runner group + Sources
# ============================================================

bridge_filename = 'NodeJSBridge.swift'

unless runner_target.source_build_phase.files_references.any? { |ref| ref&.path == bridge_filename }
  runner_group = project.main_group['Runner']
  abort('❌ 找不到 Runner group') unless runner_group

  bridge_ref = runner_group.files.find { |f| f.path == bridge_filename }
  unless bridge_ref
    bridge_ref = runner_group.new_reference(bridge_filename)
    bridge_ref.last_known_file_type = 'sourcecode.swift'
  end
  runner_target.source_build_phase.add_file_reference(bridge_ref, true)
  puts "✅ 已加 #{bridge_filename} 到 Runner target"
else
  puts "✅ #{bridge_filename} 已在 Runner target 中"
end

# ============================================================
# 2. 加 NodeMobile.xcframework 到 Frameworks group + Frameworks build phase
# ============================================================

framework_relative_path = options[:xcframework]
framework_basename = File.basename(framework_relative_path)

# Frameworks group（顶层那个）
frameworks_group = project.main_group['Frameworks']
unless frameworks_group
  frameworks_group = project.main_group.new_group('Frameworks', 'Frameworks')
end

framework_ref = frameworks_group.files.find { |f| f.path == framework_relative_path || f.name == framework_basename }
unless framework_ref
  # 计算 xcframework 相对 project_dir 的相对路径
  # project_dir = ios/Runner.xcodeproj
  # xcframework_abs = build/ios/Frameworks/NodeMobile.xcframework
  # → 相对路径 = ../../build/ios/Frameworks/NodeMobile.xcframework
  framework_rel = Pathname.new(xcframework_abs)
    .relative_path_from(Pathname.new(project_dir))
    .to_s
  framework_ref = frameworks_group.new_file(framework_rel)
  framework_ref.source_tree = '<group>'
  framework_ref.name = framework_basename
  framework_ref.last_known_file_type = 'wrapper.xcframework'
  puts "✅ 已加 #{framework_basename} 到 Frameworks group (path=#{framework_rel})"
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
