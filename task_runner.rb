class TaskRunner
  attr_reader :task, :runner_name, :pod_name, :build_root, :subnet, :pod_build_directory, :pod_cache_directory

  def self.timestamp
    Time.now.strftime("%F %T")
  end

  def initialize(task:, runner_name:, pod_name:, build_root:, cache_root:, subnet:)
    @task = task
    @runner_name = runner_name
    @pod_name = pod_name
    @build_root = build_root
    @subnet = subnet

    @pod_build_directory = "#{build_root}/#{pod_name}"
    @pod_cache_directory = "#{cache_root}/#{pod_name}"
    reset_workdir
    make_cachedir
    clear_pod
    create_network
  end

  def clear_pod
    system("docker rm -f $(docker ps -a --quiet --filter network=#{pod_name})", [:out, :err] => "/dev/null")
  end

  def create_network
    system("docker network inspect #{pod_name}", [:out, :err] => "/dev/null") ||
      system("docker network create --driver bridge#{network_options} #{pod_name}", [:out, :err] => logfile_for('network')) ||
      raise("Couldn't create docker network #{pod_name}: #{File.read(logfile_for('network')).chomp}")
  end

  def network_options
    " --subnet #{subnet}" if subnet
  end

  def run(klass)
    # instantiate one tasklet object per component (ie. container)
    tasklets = task["components"].collect do |container_name, container_details|
      klass.new(
        build_task_id: task["task_id"],
        build_id: task["build_id"],
        build_stage: task["stage"],
        build_task: task["task"],
        runner_name: runner_name,
        pod_name: pod_name,
        container_name: container_name,
        container_details: container_details,
        log_filename: logfile_for(container_name),
        workdir: workdir_for(container_name),
        cachedir: cachedir_for(container_name))
    end

    # fork and run each tasklet
    running_tasklets = tasklets.each_with_object({}) do |tasklet, results|
      puts "#{self.class.timestamp} #{tasklet} starting."
      results[tasklet.spawn_and_run] = tasklet
    end

    # if we fail to spawn a child process, we've already failed
    success = running_tasklets[nil].nil?

    # otherwise, we wait for them all to exit
    output = {}
    exit_code = {}
    while !running_tasklets.empty? do
      # wait for the first one of them to exit
      exited_child, process_status = Process.wait2
      tasklet = running_tasklets.delete(exited_child)
      output[tasklet.container_name] = tasklet.output.scrub
      exit_code[tasklet.container_name] = process_status.exitstatus
      success &= process_status.success?

      if process_status.success?
        puts "#{self.class.timestamp} #{tasklet} successful."
      else
        puts "#{self.class.timestamp} #{tasklet} failed with exit code #{exit_code[tasklet.container_name]}.  container output:\n\n\t#{output[tasklet.container_name].gsub "\n", "\n\t"}"
      end

      # depending on the tasklet, it may then tell all the others to stop
      tasklet.finished(process_status, running_tasklets)
    end

    [success, output, exit_code]
  end

protected
  def logfile_for(container_name)
    File.join(pod_build_directory, "#{container_name.tr('^A-Za-z0-9_', '_')}.log")
  end

  def workdir_for(container_name)
    File.join(pod_build_directory, container_name.tr('^A-Za-z0-9_', '_'))
  end

  def cachedir_for(container_name)
    File.join(pod_cache_directory, container_name.tr('^A-Za-z0-9_', '_'))
  end

  def reset_workdir
    FileUtils.rm_rf(pod_build_directory)
    FileUtils.mkdir_p(pod_build_directory)
  end

  def make_cachedir
    FileUtils.mkdir_p(pod_cache_directory)
  end
end
