#!/usr/bin/env ruby

require 'open3'
require 'shellwords'

DOKKU_ROOT = ENV["DOKKU_ROOT"] ||= "/home/dokku"
PLUGIN_PATH = ENV["PLUGIN_PATH"] ||= "/var/lib/dokku/plugins"

dokkurc = File.join(DOKKU_ROOT, "dokkurc")

File.file?(dokkurc) and eval(File.read(dokkurc))

unless ENV["USER"] == "dokku" or String(ARGV[0]).start_with? "plugins-install"
  system('sudo', '-u', 'dokku', '-H', 'ruby', $0, ARGV.join(' '))
  exit
end

def run arg1, *argn
  if system(arg1, *argn).nil?
    cmd = if argn.length > 1
      arg1
    else
      arg1.shellsplit[0]
    end
    $stderr.puts("sh: command not found: #{cmd}")
    exit 1
  end
end

case ARGV[0]
when "receive"
  app = ARGV[1]
  image = "dokku/#{app}"
  puts "-----> Cleaning up ..."
  run("ruby", $0, "cleanup")
  puts "-----> Building $APP ..."
  IO.popen(["dokku", "build", app], "w") do |io|
    io.write($stdin.read)
  end
  puts "-----> Releasing #{app} ..."
  run("ruby", "dokku", "release", app)
  puts "-----> Deploying #{app} ..."
  run("ruby", "dokku", "deploy", app)
  puts "=====> Application deployed:"
  puts "       $(dokku url #{app})"
  puts
when "build"
  app = ARGV[1]
  image = "dokku/#{app}"
  cache_dir = File.join(DOKKU_ROOT, app, "cache")
  args = ["docker", "run", "-i", "-a", "stdin", "progrium/buildstep", "/bin/bash", "-c", "mkdir -p /app && tar -xC /app"]
  id = Open3.popen3(*args) do |i, o|
    i.write($stdin.read)
    o.read
  end.strip
  run("test $(docker wait #{id}) -eq 0")
  run("docker commit #{id} #{image} > /dev/null")
  Dir.mkdir cache_dir unless File.directory? cache_dir
  run("pluginhook pre-build #{app}")
  id = IO.popen(["docker", "run", "-d", "-v", "#{cache_dir}:/cache", image, "/build/builder"], "r", &:read).strip
  run("docker attach #{id}")
  run("test $(docker wait #{id}) -eq 0")
  run("docker commit #{id} #{image} > /dev/null")
  run("pluginhook post-build #{app}")
when "release"
  app = ARGV[1]
  image = "dokku/#{app}"
  run("pluginhook pre-release #{app}")
  env = File.join(DOKKU_ROOT, app, "ENV")
  if File.file? env
    content = File.read(env)
    args = ["docker", "run", "-i", "-a", "stdin", image, "/bin/bash", "-c", "mkdir -p /app/.profile.d && cat > /app/.profile.d/app-env.sh"]
    id = Open.popen3(*args) do |i, o, e|
      i.write(content)
      o.read
    end.strip
    run("test $(docker wait #{id}) -eq 0")
    run("docker commit #{id} #{image} > /dev/null")
  end
  run("pluginhook post-release #{app}")
when "deploy"
  app = ARGV[1]
  image = "dokku/#{app}"
  run("pluginhook pre-deploy #{app}")

  container = File.join(DOKKU_ROOT, app, "CONTAINER")

  oldid = File.read(container).strip if File.file? container

  # start the app
  args = `: | pluginhook docker-args #{app}`.strip
  id = `docker run -d -p 5000 -e PORT=5000 #{args} #{image} /bin/bash -c "/start web"`.strip
  port = `docker port #{id} 5000 | sed 's/[0-9.]*://'`.strip

  # if we can't post-deploy successfully, kill new container
  kill_new = -> do
    run("docker inspect #{id} &> /dev/null && docker kill #{id} > /dev/null")
    ["INT", "TERM", "EXIT"].each do |sig|
      trap(sig, "DEFAULT")
    end
    Process.kill(9, 0)
  end

  # run checks first, then post-deploy hooks, which switches Nginx traffic
  ["INT", "TERM", "EXIT"].each do |sig|
    trap(sig, &kill_new)
  end
  puts "-----> Running pre-flight checks"
  run("pluginhook check-deploy #{id} #{app} #{port}")

  # now using the new container
  File.write(container, id)
  File.write(File.join(DOKKU_ROOT, app, "PORT"), port)
  File.write(File.join(DOKKU_ROOT, app, "URL"), "http://#{DOKKU_ROOT}/HOSTNAME:#{port}")

  puts "-----> Running post-deploy"
  run("pluginhook post-deploy #{app} #{port}")
  ["INT", "TERM", "EXIT"].each do |sig|
    trap(sig, "DEFAULT")
  end

  # kill the old container
  run("docker inspect #{oldid} &> /dev/null && docker kill #{oldid} > /dev/null") if oldid
when "cleanup"
  # delete all non-running container
  Process.spawn("docker ps -a | grep 'Exit' | awk '{print $1}' | xargs docker rm &> /dev/null")
  # delete unused images
  Process.spawn("docker images | grep '<none>' | awk '{print $3}' | xargs docker rmi &> /dev/null &")
when "plugins"
  puts Dir[File.join(PLUGIN_PATH, "*")].select(&File.method(:directory?))
when "plugins-install"
  run("pluginhook install")
when "plugins-install-dependencies"
  run("pluginhook dependencies")
when "deploy:all"
  Dir[File.join(DOKKU_ROOT, "*")].select(&File.method(:directory?)).each do |app|
    name = File.basename app
    run("dokku deploy #{name}")
  end
when "help", nil
  help = <<EOF
    help                                            Print the list of commands
    plugins                                         Print active plugins
    plugins-install                                 Install active plugins
EOF
  Open3.popen3("pluginhook commands help") do |i, o|
    i.write(help)
    puts o.read.lines.sort
  end
else
  files = Dir[File.join(PLUGIN_PATH, "*", "commands")]
  files.select(&File.method(:directory?)).each do |script|
    run(script, ARGV.join(" "))
  end
end