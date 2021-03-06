require 'barbeque/docker_image'
require 'barbeque/execution_log'
require 'barbeque/runner'
require 'barbeque/slack_client'

module Barbeque
  module MessageHandler
    class JobExecution
      # @param [Barbeque::Message::JobExecution] message
      # @param [Barbeque::JobQueue] job_queue
      def initialize(message:, job_queue:)
        @message = message
        @job_queue = job_queue
      end

      def run
        job_execution = Barbeque::JobExecution.find_or_initialize_by(message_id: @message.id)
        raise DuplicatedExecution if job_execution.persisted?
        job_execution.update!(job_definition: job_definition, job_queue_id: @job_queue.id)

        stdout, stderr, status = run_command
        job_execution.update!(status: status.success? ? :success : :failed, finished_at: Time.now)
        notify_slack(job_execution, status)

        log_result(job_execution, stdout, stderr)
      end

      private

      def log_result(execution, stdout, stderr)
        log = { message: @message.body.to_json, stdout: stdout, stderr: stderr }
        Barbeque::ExecutionLog.save(execution: execution, log: log)
      end

      def notify_slack(job_execution, status)
        return if job_execution.slack_notification.nil?

        client = Barbeque::SlackClient.new(job_execution.slack_notification.channel)
        if status.success?
          if job_execution.slack_notification.notify_success
            client.notify_success("*[SUCCESS]* Succeeded to execute #{job_execution_link(job_execution)}")
          end
        else
          client.notify_failure(
            "*[FAILURE]* Failed to execute #{job_execution_link(job_execution)}" \
            " #{job_execution.slack_notification.failure_notification_text}"
          )
        end
      end

      def job_execution_link(job_execution)
        "<#{job_execution_url(job_execution)}|#{job_execution.job_definition.job} ##{job_execution.id}>"
      end

      def job_execution_url(job_execution)
        Barbeque::Engine.routes.url_helpers.job_execution_url(job_execution, host: ENV['BARBEQUE_HOST'])
      end

      # @return [String] stdout
      # @return [String] stderr
      # @return [Process::Status] status
      def run_command
        image  = DockerImage.new(job_definition.app.docker_image)
        runner = Runner.create(docker_image: image)
        runner.run(job_definition.command, job_envs)
      end

      def job_envs
        {
          'BARBEQUE_JOB'         => @message.job,
          'BARBEQUE_MESSAGE'     => @message.body.to_json,
          'BARBEQUE_MESSAGE_ID'  => @message.id,
          'BARBEQUE_QUEUE_NAME'  => @job_queue.name,
          'BARBEQUE_RETRY_COUNT' => '0',
        }
      end

      def job_definition
        @job_definition ||= Barbeque::JobDefinition.joins(:app).find_by!(
          job: @message.job,
          barbeque_apps: { name: @message.application },
        )
      end
    end
  end
end
