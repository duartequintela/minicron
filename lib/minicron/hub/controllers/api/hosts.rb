require 'minicron'
require 'minicron/transport/ssh'

class Minicron::Hub::App
  # Get all hosts that a job
  # TODO: Add offset/limit
  get '/api/hosts' do
    content_type :json
    hosts = Minicron::Hub::Host.all.includes(:jobs).order(:id => :asc)
    HostSerializer.new(hosts).serialize.to_json
  end

  # Get a single host by its ID
  get '/api/hosts/:id' do
    content_type :json
    host = Minicron::Hub::Host.includes(:jobs).find(params[:id])
    HostSerializer.new(host).serialize.to_json
  end

  # Create a new host
  post '/api/hosts' do
    content_type :json
    begin
      # Load the JSON body
      request_body = Oj.load(request.body)

      # Default the value of the port
      request_body['host']['port'] ||= 22

      # Try and save the new host
      host = Minicron::Hub::Host.create(
        :name => request_body['host']['name'],
        :fqdn => request_body['host']['fqdn'],
        :host => request_body['host']['host'],
        :port => request_body['host']['port']
      )

      # Generate a new SSH key - TODO: add passphrase
      key = Minicron.generate_ssh_key('host', host.id, host.fqdn)

      # And finally we store the public key in te db with the host for convenience
      host.public_key = key.ssh_public_key
      host.save!

      # Return the new host
      HostSerializer.new(host).serialize.to_json
    # TODO: nicer error handling here with proper validation before hand
    rescue Exception => e
      status 422
      { :error => e.message }.to_json
    end
  end

  # Update an existing host
  put '/api/hosts/:id' do
    content_type :json
    begin
      # Load the JSON body
      request_body = Oj.load(request.body)

      # Find the host
      host = Minicron::Hub::Host.includes(:jobs).find(params[:id])

      # Default the value of the port
      request_body['host']['port'] ||= 22

      # Update its data
      host.name = request_body['host']['name']
      host.fqdn = request_body['host']['fqdn']
      host.host = request_body['host']['host']
      host.port = request_body['host']['port']

      host.save!

      # Return the new host
      HostSerializer.new(host).serialize.to_json
    # TODO: nicer error handling here with proper validation before hand
    rescue Exception => e
      status 422
      { :error => e.message }.to_json
    end
  end

  # Delete an existing host
  delete '/api/hosts/:id' do
    content_type :json
    begin
      Minicron::Hub::Host.transaction do
        # Look up the host
        host = Minicron::Hub::Host.includes({ :jobs => :schedules }).find(params[:id])

        # Try and delete the host
        Minicron::Hub::Host.destroy(params[:id])

        # Get an ssh instance and open a connection
        ssh = Minicron::Transport::SSH.new(
          :host => host.host,
          :port => host.port,
          :private_key => "~/.ssh/minicron_host_#{host.id}_rsa"
        )

        # Get an instance of the cron class
        cron = Minicron::Cron.new(ssh)

        # Delete the host from the crontab
        cron.delete_host(host)

        # Tidy up
        ssh.close

        # Delete the pub/priv key pair
        private_key_path = Minicron.sanitize_filename(File.expand_path("~/.ssh/minicron_host_#{host.id}_rsa"))
        public_key_path = Minicron.sanitize_filename(File.expand_path("~/.ssh/minicron_host_#{host.id}_rsa.pub"))
        File.delete(private_key_path)
        File.delete(public_key_path)

        # This is what ember expects as the response
        status 204
      end
    # TODO: nicer error handling here with proper validation before hand
    rescue Exception => e
      status 422
      { :error => e.message }.to_json
    end
  end

  # Used to test an SSH connection for a host
  get '/api/hosts/:id/test_ssh' do
    begin
      # Get the host
      host = Minicron::Hub::Host.find(params[:id])

      # Set up the ssh instance
      ssh = Minicron::Transport::SSH.new(
        :host => host.host,
        :port => host.port,
        :private_key => "~/.ssh/minicron_host_#{host.id}_rsa"
      )

      # Open the connection
      conn = ssh.open

      # Check if the crontab is readable
      read = conn.exec!('test -r /etc/crontab && echo "y" || echo "n"').strip

      # Check if the crontab is writeable
      write = conn.exec!('test -w /etc/crontab && echo "y" || echo "n"').strip

      # Tidy up
      ssh.close

      # Return the test results as JSON
      {
        :connect => true,
        :read => read == 'y',
        :write => write == 'y'
      }.to_json
    rescue Exception => e
      status 422
      { :connect => false, :error => e.message }.to_json
    end
  end
end
