require 'spec_helper'
require 'que/testing'
require 'timecop'
require 'yaml'
require 'active_record'
require 'active_support/core_ext/numeric/time'

RSpec.describe Que::Scheduler::SchedulerJob do
  QSSJ = described_class
  QS = Que::Scheduler
  PARSER = QS::ScheduleParser
  RESULT = QS::ScheduleParserResult

  context 'scheduling' do
    before(:each) do
      expect(::ActiveRecord::Base).to receive(:transaction) do |_, &block|
        block.call
      end
      Que.adapter.jobs.clear
    end

    let(:run_time) { Time.zone.parse('2017-11-08T13:50:32') }

    around(:each) do |example|
      Timecop.freeze(run_time) do
        example.run
      end
    end

    it 'enqueues nothing having loaded the dictionary on the first run' do
      run_test(nil, {}, [])
    end

    it 'enqueues nothing if it knows about a job, but it is not overdue' do
      run_test(
        {
          last_run_time: (run_time - 15.minutes).iso8601,
          job_dictionary: %w[HalfHourlyTestJob]
        },
        {},
        %w[HalfHourlyTestJob]
      )
    end

    it 'enqueues nothing if it knows about one job, and a deploy has added a new one' do
      run_test(
        {
          last_run_time: (run_time - 15.minutes).iso8601,
          job_dictionary: %w[HalfHourlyTestJob]
        },
        {},
        %w[HalfHourlyTestJob SomeNewJob]
      )
    end

    it 'enqueues known jobs that are overdue' do
      run_test(
        {
          last_run_time: (run_time - 45.minutes).iso8601,
          job_dictionary: %w[HalfHourlyTestJob]
        },
        { HalfHourlyTestJob => [[]] },
        %w[HalfHourlyTestJob]
      )
    end

    it 'can enqueue the same job multiple times with different args' do
      run_test(
        {
          last_run_time: (run_time - 45.minutes).iso8601,
          job_dictionary: %w[HalfHourlyTestJob]
        },
        { HalfHourlyTestJob => [['foo'], ['bar']] },
        %w[HalfHourlyTestJob]
      )
    end

    it 'should remove jobs from the dictionary that are no longer in the schedule' do
      run_test(
        {
          last_run_time: (run_time - 45.minutes).iso8601,
          job_dictionary: %w[HalfHourlyTestJob OldRemovedJob]
        },
        { HalfHourlyTestJob => [[]] },
        %w[HalfHourlyTestJob]
      )
    end

    it 'handles the old method of passing in two args' do
      scheduler_job_args = QS::SchedulerJobArgs.prepare_scheduler_job_args(
        last_run_time: Time.zone.now.iso8601, job_dictionary: %w[HalfHourlyTestJob]
      )
      expect(PARSER).to receive(:parse).with(QSSJ.scheduler_config, scheduler_job_args).and_return(
        RESULT.new([], [])
      )
      QSSJ.run(Time.zone.now.iso8601, %w[HalfHourlyTestJob])
    end

    def run_test(initial_job_args, to_schedule, new_dictionary)
      scheduler_job_args = QS::SchedulerJobArgs.prepare_scheduler_job_args(initial_job_args)
      expect(PARSER).to receive(:parse).with(QSSJ.scheduler_config, scheduler_job_args).and_return(
        RESULT.new(to_schedule, new_dictionary)
      )
      if initial_job_args
        QSSJ.run(initial_job_args)
      else
        QSSJ.run
      end
      expect_scheduled(to_schedule, new_dictionary)
    end

    # This method checks what jobs have been enqueued against a provided list. In addition, the
    # main scheduler job should have enqueued itself.
    def expect_scheduled(list, new_dictionary)
      itself_jobs = Que.adapter.jobs.delete(QS::SchedulerJob)
      expect(itself_jobs.count).to eq(1)
      expect(itself_jobs.first.to_h).to eq(
        queue: nil,
        priority: 0,
        run_at: run_time.beginning_of_minute + QSSJ::SCHEDULER_FREQUENCY,
        job_class: 'Que::Scheduler::SchedulerJob',
        args: [{ last_run_time: run_time.iso8601, job_dictionary: new_dictionary }]
      )

      all_enqueued = Que.adapter.jobs.each_key.map do |job_class|
        job_class_items = Que.adapter.jobs.delete(job_class)
        args = job_class_items.map do |job_class_item|
          expect(job_class_item.to_h[:queue]).to eq(nil)
          expect(job_class_item.to_h[:priority]).to eq(nil)
          expect(job_class_item.to_h[:run_at]).to eq(nil)
          expect(job_class_item.to_h[:job_class]).to eq(job_class.to_s)
          job_class_item.to_h[:args]
        end
        [job_class, args]
      end.to_h
      expect(all_enqueued).to eq(list)
    end
  end

  context 'configuration' do
    # The scheduler job must run at the highest priority, as it must serve the highest common
    # denominator of all schedulable jobs.
    it 'should run the scheduler at highest priority' do
      expect(QSSJ.instance_variable_get('@priority')).to eq(0)
    end
  end
end
