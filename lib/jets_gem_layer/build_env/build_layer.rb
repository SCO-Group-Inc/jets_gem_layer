# frozen_string_literal: true

# Substantial portions of this file attributed to lambda_layer_cake (c) 2019 Logan Bowers

require 'English'
require 'open3'
require 'fileutils'

# This script runs in the public.ecr.aws/sam/build-ruby docker container
# to build native gems and libs which end up in the layer zip file
def main
  Dir.chdir('/tmp/inputs')

  if ENV['GEM_LAYER_PACKAGE_DEPENDENCIES']
    warn("Installing package dependencies: #{ENV.fetch('GEM_LAYER_PACKAGE_DEPENDENCIES')}...")

    warn('Installing openssl-devel...')
    system('dnf', 'install', '-y', 'openssl-devel')

    gem_deps = ENV.fetch('GEM_LAYER_PACKAGE_DEPENDENCIES').split(',')
    unless system('dnf', 'install', '-y', *gem_deps)
      warn('Could not install build dependency packages, aborting...')
      exit 2
    end
  end

  warn('Building gems...')
  FileUtils.mkdir_p('/tmp/build/bundle')
  system('bundle', 'config', 'set', 'force_ruby_platform', 'true')
  system('bundle', 'config', 'set', '--local', 'deployment', 'true')
  system('bundle', 'config', 'set', '--local', 'path', '/tmp/build/bundle')
  system('bundle', 'config', 'set', '--local', 'without', 'development:test')
  unless system('bundle', 'install')
    warn('Error while building gems, aborting...')
    exit 3
  end

  warn('Copying libs...')
  required_libs = Set.new
  pkg_cache = Hash.new do |h, k|
    pkgs_str, = Open3.capture2('dnf', 'repoquery', '--installed', '-f', k)
    h[k] = pkgs_str
  end

  Dir['/tmp/build/**/*.so*'].each do |lib|
    deps_str, status = Open3.capture2('ldd', lib)
    unless status.exitstatus.zero?
      warn("Couldn't run ldd! Status code: #{status}, ignoring…")
      # exit 3
    end
    deps = deps_str.split("\n").collect { |d_str| d_str[%r{(?<==>\s)(/\S+)}] }.compact
    next unless deps.length.positive?

    deps.each do |dep|
      pkgs = pkg_cache[dep].split("\n")
      required_libs << dep if pkgs.length.positive?
    end
  end

  FileUtils.mkdir_p('/tmp/outputs/lib')
  FileUtils.cp(required_libs.to_a, '/tmp/outputs/lib')

  # These files are not needed at runtime
  FileUtils.rm_rf(Dir['/tmp/build/bundle/ruby/*/cache'])
  FileUtils.rm_rf(Dir['/tmp/build/bundle/ruby/*/gems/*/test'])

  # Move outputs into place for zipping up
  FileUtils.mkdir_p('/tmp/outputs/ruby')
  FileUtils.cp_r('/tmp/build/bundle/ruby', '/tmp/outputs/ruby')
  FileUtils.mv('/tmp/outputs/ruby/ruby', '/tmp/outputs/ruby/gems')
  FileUtils.chmod_R(0o755, '/tmp/outputs')

  warn('Successfully generated gems and dependencies...')
end

main
true
