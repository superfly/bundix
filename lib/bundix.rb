require 'bundler'
require 'json'
require 'open-uri'
require 'open3'
require 'pp'

require_relative 'bundix/version'
require_relative 'bundix/source'
require_relative 'bundix/nixer'

class Bundix
  NIX_INSTANTIATE = 'nix-instantiate'
  NIX_PREFETCH_URL = 'nix-prefetch-url'
  NIX_PREFETCH_GIT = 'nix-prefetch-git'
  NIX_HASH = 'nix-hash'
  NIX_SHELL = 'nix-shell'

  SHA256_32 = %r(^[a-z0-9]{52}$)

  attr_reader :options, :target_platform

  attr_accessor :fetcher

  class Dependency < Bundler::Dependency
    def initialize(name, version, options={}, &blk)
      super(name, version, options, &blk)
      @bundix_version = version
    end

    attr_reader :version
  end

  def initialize(options)
    @options = { quiet: false, tempfile: nil }.merge(options)
    @target_platform = options[:platform] ? Gem::Platform.new(options[:platform]) : Gem::Platform::RUBY
    @fetcher = Fetcher.new
  end

  def convert
    cache = parse_gemset
    lock = parse_lockfile
    dep_cache = build_depcache(lock)

    lock.specs.group_by(&:name).each.with_object({}) do |(name, specs), gems|
      # reverse so git/plain-ruby sources come last
      spec = specs.reverse.find {|s| s.platform == Gem::Platform::RUBY || s.platform =~ target_platform }
      next unless spec
      gem = find_cached_spec(spec, cache) || convert_spec(spec, cache, dep_cache)
      gems.merge!(gem)

      if spec.dependencies.any?
        gems[spec.name]['dependencies'] = spec.dependencies.map(&:name) - ['bundler']
      end
    end
  end

  def groups(spec, dep_cache)
    {groups: dep_cache.fetch(spec.name).groups}
  end

  PLATFORM_MAPPING = {}

  {
    "ruby" => [{engine: "ruby"}, {engine:"rbx"}, {engine:"maglev"}],
    "mri" => [{engine: "ruby"}, {engine: "maglev"}],
    "rbx" => [{engine: "rbx"}],
    "jruby" => [{engine: "jruby"}],
    "mswin" => [{engine: "mswin"}],
    "mswin64" => [{engine: "mswin64"}],
    "mingw" => [{engine: "mingw"}],
    "truffleruby" => [{engine: "ruby"}],
    "x64_mingw" => [{engine: "mingw"}],
  }.each do |name, list|
    PLATFORM_MAPPING[name] = list
    %w(1.8 1.9 2.0 2.1 2.2 2.3 2.4 2.5 2.6).each do |version|
      PLATFORM_MAPPING["#{name}_#{version.sub(/[.]/,'')}"] = list.map do |platform|
        platform.merge(:version => version)
      end
    end
  end

  def platforms(spec, dep_cache)
    # c.f. Bundler::CurrentRuby
    platforms = dep_cache.fetch(spec.name).platforms.map do |platform_name|
      PLATFORM_MAPPING[platform_name.to_s]
    end.flatten

    # 'platforms' is the Bundler DSL for including a gem if we're on a certain platform.
    # 'target_platform' is the platform that bundix is currently resolving gem-specs for.
    # 'gem_platform' is the platform of the resulting spec.
    # (eg we might be resolving gem-specs for x86_64-darwin, but if there's not a suitable
    # precompiled gem available, then gem_platform will just be 'ruby')
    {
      platforms: platforms,
      target_platform: target_platform.to_s,
      gem_platform: spec.platform.to_s,
    }
  end

  def convert_spec(spec, cache, dep_cache)
    {
      spec.name => [
        platforms(spec, dep_cache),
        groups(spec, dep_cache),
        Source.new(spec, fetcher).convert,
      ].inject(&:merge),
    }
  rescue => ex
    warn "Skipping #{spec.name}: #{ex}"
    puts ex.backtrace
    {spec.name => {}}
  end

  def find_cached_spec(spec, cache)
    name, cached = cache.find{|k, v|
      next unless k == spec.name
      next unless cached_source = v['source']
      next unless target_platform.to_s == v['target_platform']

      case spec_source = spec.source
      when Bundler::Source::Git
        next unless cached_source['type'] == 'git'
        next unless cached_rev = cached_source['rev']
        next unless spec_rev = spec_source.options['revision']
        spec_rev == cached_rev
      when Bundler::Source::Rubygems
        next unless cached_source['type'] == 'gem'
        v['version'] == spec.version.to_s
      end
    }

    {name => cached} if cached
  end

  def build_depcache(lock)
    definition = Bundler::Definition.build(options[:gemfile], options[:lockfile], false)
    dep_cache = {}

    definition.dependencies.each do |dep|
      dep_cache[dep.name] = dep
    end

    lock.specs.each do |spec|
      dep_cache[spec.name] ||= Dependency.new(spec.name, nil, {})
    end

    begin
      changed = false
      lock.specs.each do |spec|
        as_dep = dep_cache.fetch(spec.name)

        spec.dependencies.each do |dep|
          cached = dep_cache.fetch(dep.name) do |name|
            if name != "bundler"
              raise KeyError, "Gem dependency '#{name}' not specified in #{lockfile}"
            end
            dep_cache[name] = Dependency.new(name, lock.bundler_version, {})
          end

          if !((as_dep.groups - cached.groups) - [:default]).empty? or !(as_dep.platforms - cached.platforms).empty?
            changed = true
            dep_cache[cached.name] = (Dependency.new(cached.name, nil, {
              "group" => as_dep.groups | cached.groups,
              "platforms" => as_dep.platforms | cached.platforms
            }))

            cc = dep_cache[cached.name]
          end
        end
      end
    end while changed

    return dep_cache
  end

  def parse_gemset
    path = File.expand_path(options[:gemset])
    return {} unless File.file?(path)
    json = Bundix.sh(NIX_INSTANTIATE, '--eval', '-E', %(
      builtins.toJSON (import #{Nixer.serialize(path)}))
    )
    JSON.parse(json.strip.gsub(/\\"/, '"')[1..-2])
  end

  def parse_lockfile
    lock = Bundler::LockfileParser.new(File.read(options[:lockfile]))
    if !lock.platforms.include?(target_platform)
      raise KeyError, "#{target_platform} not listed in gemfile. Try `bundle lock --add-platform #{target_platform}`"
    end
    lock
  end

  def self.sh(*args, &block)
    out, status = Open3.capture2(*args)
    unless block_given? ? block.call(status, out) : status.success?
      puts "$ #{args.join(' ')}" if $VERBOSE
      puts out if $VERBOSE
      fail "command execution failed: #{status}"
    end
    out
  end
end
