class Minicron::Hub::App
  get '/jobs' do
    # Look up all the jobs
    @jobs = Minicron::Hub::Job.all.order(:created_at => :desc).includes(:host, :executions)

    erb :'jobs/index', :layout => :'layouts/app'
  end

  get '/job/:id' do
    # Look up the job
    @job = Minicron::Hub::Job.includes(:host, :executions, :schedules).find(params[:id])

    erb :'jobs/show', :layout => :'layouts/app'
  end

  get '/jobs/new' do
    # Empty instance to simplify views
    @previous = Minicron::Hub::Job.new

    # All the hosts for the select dropdown
    @hosts = Minicron::Hub::Host.all

    erb :'jobs/new', :layout => :'layouts/app'
  end

  post '/jobs/new' do
    begin
      # All the hosts for the select dropdown
      @hosts = Minicron::Hub::Host.all

      # First we need to look up the host
      host = Minicron::Hub::Host.find(params[:host])

      # Try and save the new job
      job = Minicron::Hub::Job.create!(
        :job_hash => Minicron::Transport.get_job_hash(params[:command], host.fqdn),
        :name => params[:name],
        :user => params[:user],
        :command => params[:command],
        :host_id => host.id
      )

      job.save!

      # Redirect to the new job
      redirect "#{route_prefix}/job/#{job.id}"
    # TODO: nicer error handling here with proper validation before hand
    rescue Exception => e
      @previous = params
      @error = e.message
      erb :'jobs/new', :layout => :'layouts/app'
    end
  end

  get '/job/:id/edit' do
    # Find the job
    @job = Minicron::Hub::Job.includes(:host).find(params[:id])

    # All the hosts for the select dropdown
    @hosts = Minicron::Hub::Host.all

    erb :'jobs/edit', :layout => :'layouts/app'
  end

  post '/job/:id/edit' do
    begin
      # All the hosts for the select dropdown
      @hosts = Minicron::Hub::Host.all

      Minicron::Hub::Job.transaction do
        # Find the job
        @job = Minicron::Hub::Job.includes(:host).find(params[:id])

        # Store a copy of the current job user in case we need to change it
        old_user = @job.user

        # Update the name and user
        @job.name = params[:name]
        @job.user = params[:user]

        # Only update the job user if it has changed
        if old_user != @job.user
          ssh = Minicron::Transport::SSH.new(
            :user => @job.host.user,
            :host => @job.host.host,
            :port => @job.host.port,
            :private_key => "~/.ssh/minicron_host_#{@job.host.id}_rsa"
          )

          # Get an instance of the cron class
          cron = Minicron::Cron.new(ssh)

          # Update the job schedules in the crontab
          cron.update_user(@job, old_user, @job.user)

          # Tidy up
          ssh.close
        end

        @job.save!

        # Redirect to the updated job
        redirect "#{route_prefix}/job/#{@job.id}"
      end
    # TODO: nicer error handling here with proper validation before hand
    rescue Exception => e
      @job.restore_attributes
      @error = e.message
      erb :'jobs/edit', :layout => :'layouts/app'
    end
  end

  get '/job/:id/delete' do
    # Look up the job
    @job = Minicron::Hub::Job.find(params[:id])

    erb :'jobs/delete', :layout => :'layouts/app'
  end

  post '/job/:id/delete' do
    begin
      # Look up the job
      @job = Minicron::Hub::Job.find(params[:id])

      Minicron::Hub::Job.transaction do
        # Try and delete the job
        Minicron::Hub::Job.destroy(params[:id])

        # Get an ssh instance
        ssh = Minicron::Transport::SSH.new(
          :user => @job.host.user,
          :host => @job.host.host,
          :port => @job.host.port,
          :private_key => "~/.ssh/minicron_host_#{@job.host.id}_rsa"
        )

        # Get an instance of the cron class
        cron = Minicron::Cron.new(ssh)

        # Delete the job from the crontab
        cron.delete_job(@job)

        # Tidy up
        ssh.close

        redirect "#{route_prefix}/jobs"
      end
    # TODO: nicer error handling here with proper validation before hand
    rescue Exception => e
      @error = e.message
      erb :'jobs/delete', :layout => :'layouts/app'
    end
  end

  get '/job/:job_id/schedule/:schedule_id' do
    # Look up the schedule
    @schedule = Minicron::Hub::Schedule.includes(:job).find(params[:id])

    # Look up the job
    @job = Minicron::Hub::Job.find(params[:job_id])

    erb :'jobs/schedules/show', :layout => :'layouts/app'
  end

  get '/job/:job_id/schedules/new' do
    # Empty instance to simplify views
    @previous = Minicron::Hub::Schedule.new

    # Look up the job
    @job = Minicron::Hub::Job.find(params[:job_id])

    erb :'jobs/schedules/new', :layout => :'layouts/app'
  end

  post '/job/:job_id/schedules/new' do
    begin
      # Look up the job
      @job = Minicron::Hub::Job.find(params[:job_id])

      # First we need to check a schedule like this doesn't already exist
      exists = Minicron::Hub::Schedule.exists?(
        :minute => params[:minute],
        :hour => params[:hour],
        :day_of_the_month => params[:day_of_the_month],
        :month => params[:month],
        :day_of_the_week => params[:day_of_the_week],
        :special => params[:special],
        :job_id => params[:job_id]
      )

      if exists
        raise Exception, 'That schedule already exists for this job'
      end

      Minicron::Hub::Schedule.transaction do
        # Create the new schedule
        schedule = Minicron::Hub::Schedule.create(
          :minute => params[:minute],
          :hour => params[:hour],
          :day_of_the_month => params[:day_of_the_month],
          :month => params[:month],
          :day_of_the_week => params[:day_of_the_week],
          :special => params[:special],
          :job_id => params[:job_id]
        )

        # Get the job and host for the schedule
        job = Minicron::Hub::Job.includes(:host).find(schedule.job_id)

        # Get an ssh instance
        ssh = Minicron::Transport::SSH.new(
          :user => job.host.user,
          :host => job.host.host,
          :port => job.host.port,
          :private_key => "~/.ssh/minicron_host_#{job.host.id}_rsa"
        )

        # Get an instance of the cron class
        cron = Minicron::Cron.new(ssh)

        # Add the schedule to the crontab
        cron.add_schedule(job, schedule.formatted)

        # Tidy up
        ssh.close

        # And finally save it
        schedule.save!

        # Redirect to the updated job
        redirect "#{route_prefix}/job/#{@job.id}"
      end
    # TODO: nicer error handling here with proper validation before hand
    rescue Exception => e
      @error = e.message
      erb :'jobs/schedules/new', :layout => :'layouts/app'
    end
  end
end
