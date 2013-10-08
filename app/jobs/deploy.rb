require 'net/ssh/shell'

class Deploy
  attr_reader :job_id

  def initialize(id)
    @job_id, @job = id, JobHistory.find(id)
    @stopped = false
  end

  def perform
    @job.run!

    options = { :port => 2222, :forward_agent => true, :timeout => 20 }

    if ENV["DEPLOY_KEY"]
      options[:key_data] = [ENV["DEPLOY_KEY"]]
    end

    if ssh_deploy(options)
      @job.success!
    else
      @job.failed!
    end

    redis.quit
  end

  def ssh_deploy(options)
    socket = Rails.root.join("tmp/auth_sock")

    if Rails.env.production? && !File.exist?(socket)
      Process.spawn(Rails.root.join("lib/ssh-agent.sh").to_s)

      time = Time.now

      until File.exist?(socket)
        if stopped?
          publish_messages("Deploy stopped.\n")
          return false
        elsif (Time.now - time) >= 5
          publish_messages("SSH Agent failed to start.\n")
          return false
        end
      end
    end

    ENV["SSH_AUTH_SOCK"] = File.readlink(socket)

    @ssh = Net::SSH.start("admin01.ord.zdsys.com", "deploy", options) do |ssh|
      ssh.shell do |sh|
        [
          "cd #{@job.project.name.parameterize("_")}",
          "git fetch -ap",
          "git reset --hard #{@job.sha}",
          "capsu \"$(pwd)\" #{@job.environment} deploy TAG=#{@job.sha}"
        ].each do |command|
          if !exec!(sh, command)
            publish_messages("Failed to execute \"#{command}\"")
            return false
          end
        end
      end
    end

    true
  rescue Net::SSH::ConnectionTimeout
    publish_messages("SSH connection timeout.")
    false
  rescue IOError => e
    Rails.logger.info("Deploy failed: #{e.message}")
    Rails.logger.info(e.backtrace)

    publish_messages("Deploy failed.")
    false
  end

  def stop
    return if !@job || @ssh.try(:closed?)

    @stopped = true
    Rails.logger.info("Deploy #{@job_id} stopped")
  end

  # When not on Heroku, should be changed
  # to read from a :stopped redis key
  def stopped?
    @stopped
  end

  def exec!(shell, command)
    process = shell.execute(command)

    process.on_output do |ch, data|
      publish_messages(data)
    end

    process.on_error_output do |ch, type, data|
      publish_messages(data, "**ERR")
    end

    process.manager.channel.on_process do
      return false if stopped?
      @job.save if @job.changed?

      if message = get_message
        process.send_data("#{message}\n")
      end
    end

    shell.wait!
    process.exit_status == 0
  end

  def get_message
    redis.get("#{@job.channel}:input").tap do |message|
      redis.del("#{@job.channel}:input") if message
    end
  end

  def publish_messages(data, prefix = "")
    messages = data.split(/\r?\n|\r/).
      map(&:lstrip).reject(&:blank?)

    if prefix.present?
      messages.map! do |msg|
        "#{prefix}#{msg}"
      end
    end

    messages.each do |message|
      @job.log += "#{message}\n"
      redis.publish(@job.channel, message)
      Rails.logger.info(message)
    end
  end

  def redis
    @redis ||= Redis.driver
  end
end
