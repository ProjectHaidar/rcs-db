require 'archive/tar/minitar'
require 'uuidtools'
require 'fileutils'
require 'rcs-common/trace'
require 'rcs-common/temporary'

# require all the controllers
Dir[File.dirname(__FILE__) + '/tasks/*.rb'].each do |file|
  require_relative file
end

module RCS
module DB

class TarGzCompression
  include Archive::Tar
  
  def initialize(fd)
    sgz = Zlib::GzipWriter.new(fd)
    @tar = Minitar::Output.new(sgz)
  end
  
  def add_stream(path, string)
    Minitar::pack_stream(path, StringIO.new(string), @tar)
  end
  
  def add_file(path, rename_to = nil)
    h = {name: path, as: (rename_to.nil? ? path : rename_to)}
    Minitar::pack_file(h, @tar)
  end
  
  def add_file_as(path, path_in_tar)
  
  end
  
  def close
    @tar.close
  end
end

class DummyTask
  extend TaskGenerator
  
  store_in :file, 'temp'
  multi_file
  
  def total
    100
  end
  
  def next_entry
    100.times do |n|
      filename = "dummy#{n}.txt"
      @description = "generating '#{filename}'"
      
      content = "This is file #{filename}, generated especially for you by our most skilled gerbils."
      yield 'stream', filename, content
    end
  end
end

# TODO: support single-file and multi-file tasks
# for single files, progress should be reported on # of lines or similar
# for multi files, progress is by number of files

class Task
  include RCS::Tracer
  
  attr_reader :_id, :total, :current, :resource, :desc, :type, :file_name, :file_size, :status
  
  def initialize(type, file_name, params)
    @_id = UUIDTools::UUID.random_create.to_s
    @file_name = file_name
    @type = type
    @current = 0
    @desc = ''
    @time = Time.now
    @status = :in_progress
    @generator = Task.generator_class(@type).new(params)
    @total = @generator.total
    @resource = {type: @generator.destination, _id: @_id, file_name: @file_name}
  end
  
  def self.generator_class(type)
    @generator_class || eval("#{type.downcase.capitalize}Task")
  end
  
  def self.compressor_class
    @compressor_class || TarGzCompression
  end
  
  def self.digest_class
    @digest_class || Digest::SHA1
  end
  
  def sha1(path)
    Task.digest_class.new.file(path).hexdigest
  end
  
  def step
    @current += 1
  end
  
  def finished?
    @status == :finished
  end

  def error?
    @status == :error
  end
  
  def download_available?
    @status == :download_available
  end

  def downloading?
    @status == :downloading
  end
  
  def finished
    @status = :finished
    trace :debug, "Task #{@_id} FINISHED"
  end

  def error
    @status = :error
    trace :debug, "Task #{@_id} ERROR"
  end

  def downloading
    @status = :downloading
    trace :debug, "Task #{@_id} DOWNLOADING"
  end
  
  def download_available
    @status = :download_available
    trace :debug, "Task #{@_id} DOWNLOAD AVAILABLE"
  end
  
  def stop!
    trace :info, "cancelling task #{@_id}"
    finished
  end
  
  def run
    process_build = Proc.new do
      begin
        @generator.next_entry do
          break if finished?
          @desc = @generator.description
          step
        end
        @desc = 'Saving'
        FileUtils.cp(@generator.builder.path(@generator.builder.outputs.first), Config.instance.temp(@_id))
        @resource[:size] = File.size(Config.instance.temp(@_id))
        download_available
        trace :info, "Task #{@_id} completed."
      rescue Exception => e
        trace :error, "Cannot build: #{e.message}"
        trace :fatal, "EXCEPTION: [#{e.class}] " << e.backtrace.join("\n")
        @desc = "ERROR: #{e.message}"
        error
      ensure
        @generator.builder.clean
      end
    end #build
    
    process_single_file = Proc.new do
      begin
        #identify where results should be stored
        destination = File.new(Config.instance.temp(@_id), 'wb+')
        tmp_file = File.new(Config.instance.temp("#{@_id}_temp"), 'wb+')
        compressor = Task.compressor_class.new destination
        @generator.next_entry do |chunk|
          break if finished?
          @desc = @generator.description
          tmp_file.write chunk
          step
        end
        compressor.add_file(tmp_file.path, @generator.filename)
        @resource[:size] = File.size(destination.path)
        download_available
        trace :info, "Task #{@_id} completed."
      rescue Exception => e
        @desc = "ERROR: #{e.message}"
        error
      ensure
        compressor.close
      end
    end #single_file
    
    # TODO: refactor for folder delete
    process_multi_file = Proc.new do
      
      # temporary file is our task id
      begin
        tmpfile = Temporary.file('temp', @_id)
        compressor = Task.compressor_class.new tmpfile
        @generator.next_entry do |type, entry, content|
          
          break if finished?
          
          @desc = @generator.description
          case type
            when 'stream'
              compressor.add_stream entry, content
            when 'file'
              compressor.add_file entry
          end
          step
        end
        @resource[:size] = File.size(tmpfile.path)
        download_available
        trace :info, "Task #{@_id} completed."
      rescue Exception => e
        @desc = "ERROR: #{e.message}"
        error
      ensure
        compressor.close
      end
    end # multi_file
    
    case @generator.class.gen_type
      when :multi_file
        EM.defer process_multi_file
      when :build
        EM.defer process_build
      when :single_file
        EM.defer process_single_file
      else
        raise "Invalid task type."
    end
  end
end # Task

class TaskManager
  include Singleton
  include RCS::Tracer
  
  def initialize
    @tasks = Hash.new
    #Task.instance_eval { @generator_class = DummyTask }
  end
  
  def create(user, type, file_name, params = {})
    @tasks[user] ||= Hash.new
    
    # check task file_name is unique, we cannot have 2 tasks stored in the same file for a single user
    @tasks[user].each_pair do |id, task|
      puts task.inspect
      return nil if task.file_name == file_name and task.error? == false
    end
    
    task = Task.new type, file_name, params
    trace :debug, "Creating task #{task._id} of type #{type} for user '#{user}', saving to '#{file_name}'"
    
    begin
      task.run
    rescue Exception => e
      trace :error, "Invalid task: #{e.backtrace}"
      return nil
    end
    
    @tasks[user][task._id] = task
    task
  end
  
  def get(user, id)
    trace :debug, "Getting task #{id} for user '#{user}'"
    @tasks[user][id] rescue nil
  end
  
  def list(user)
    #trace :debug, "List of tasks for user '#{user}': #{@tasks[user]}"
    
    tasks = @tasks[user]
    tasks ||= {}
    
    tasks.values
  end
  
  def delete(user, task_id)
    trace :info, "Deleting task #{task_id} for user '#{user}'"
    task = @tasks[user][task_id]
    task.stop! unless task.nil?
    @tasks[user].delete task_id
    
    FileUtils.rm_rf(Config.instance.temp("#{task_id}*"))
    
  end
  
  def download(user, task_id)
    trace :info, "Downloading task #{task_id} for user '#{user}'"

    path = Config.instance.temp(task_id)
    
    # check that task is owned by the user and the corresponding file exists
    return nil if @tasks[user][task_id].nil?
    return nil unless File.exists?(path)

    callback = proc {
      @tasks[user][task_id].finished
      trace :info, "Task #{task_id} completed. cleaning up."
      FileUtils.rm_rf(path)
    }

    @tasks[user][task_id].downloading

    return path, callback
  end
end # TaskManager

end # DB::
end # RCS::
