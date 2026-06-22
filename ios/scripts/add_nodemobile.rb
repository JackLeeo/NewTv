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

xcframework_abs = File.expand_path(options[:xcframework], File.dirname(options[:pbxproj]))
unless Dir.exist?(xcframework_abs)
  abort("❌ 找不到 xcframework: #{xcframework_abs}")
end

project_path = File.expand_path(options[:pbxproj])
unless File.exist?(project_path)
  abort("❌ 找不到 pbxproj: #{project_path}")
end

project = Xcodeproj::Project.open(project_path)
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
  framework_ref = frameworks_group.new_file(File.expand_path(framework_relative_path, File.dirname(options[:pbxproj])))
  framework_ref.source_tree = '<group>'
  framework_ref.name = framework_basename
  framework_ref.last_known_file_type = 'wrapper.xcframework'
  puts "✅ 已加 #{framework_basename} 到 Frameworks group"
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
puts "💾 已保存 #{project_path}"
puts ''
puts '🔍 最终状态：'
puts "  - Runner target sources: #{runner_target.source_build_phase.files_references.map(&:path).compact.uniq.join(', ')}"
puts "  - Runner target frameworks: #{runner_target.frameworks_build_phase.files_references.map(&:path).compact.uniq.join(', ')}"
embed_phase&.files_references&.each do |f|
  puts "  - Embed: #{f.path}"
end
