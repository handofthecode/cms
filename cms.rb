require 'sinatra'
require 'sinatra/reloader'
require 'sinatra/content_for'
require 'tilt/erubis'
require 'redcarpet'
require 'yaml'
require 'bcrypt'

configure do
  enable :sessions
  set :session_secret, 'secret'
end

IMAGE_TYPES = ['.jpg', '.jpeg', '.png'].freeze
TEXT_TYPES =  ['.txt', '.md'].freeze
ALL_TYPES = IMAGE_TYPES + TEXT_TYPES

def testing?
  ENV['RACK_ENV'] == 'test'
end

def credentials_path
  if testing?
    File.expand_path('../test/users.yml', __FILE__)
  else
    File.expand_path('../users.yml', __FILE__)
  end
end

def load_user_credentials
  YAML.load_file(credentials_path)
end

def valid_credentials?(username, password)
  return false if invalid_string(username) || invalid_string(password)
  credentials = load_user_credentials
  return false unless credentials.key?(username)
  bcrypt_pass = BCrypt::Password.new(credentials[username])
  bcrypt_pass == password
end

def data_path
  if testing?
    File.expand_path('../test/data', __FILE__)
  else
    File.expand_path('../data', __FILE__)
  end
end

def signed_in?
  !!session[:username]
end

def redirect_if_signed_out
  return nil if signed_in?
  session[:error] = 'You must be signed in to do that'
  redirect '/'
end

def invalid_edit
  file = params[:file]
  ext = ext_name(file)
  return "#{ext} files can't be edited" unless valid_type?(file)
  no_file(file)
end

def invalid_string(n, type = 'name')
  return "A #{type} is required" if n.empty?
  "The #{type} may not include special characters." if
    n.gsub(/[^A-Za-z1-9!.?,_ ]*/, '') != n
end

def invalid_textfile(filename)
  invalid_name = invalid_string(filename)
  return invalid_name if invalid_name
  return nil if text_file?(filename)
  'Your file name must have a proper text file extension'
end

def invalid_rename(filename)
  invalid_name = invalid_string(filename)
  return invalid_name if invalid_name
  return 'File name in use' if file_exists(filename)
end

def invalid_signup(username, password)
  invalid_username = invalid_string(username)
  return invalid_username if invalid_username
  invalid_password = invalid_string(password, 'password')
  return invalid_password if invalid_password
  return 'Username taken' if load_user_credentials.key? username
end

def file_exists(file)
  files_array.any? { |el| el.casecmp(file).zero? }
end

def no_file(file)
  "\"#{file}\" does not exist." unless file_exists(file)
end

def check_file_edit
  if session[:temp] == params[:content]
    "\"#{params[:filename]}\" was unchanged"
  else
    "\"#{params[:filename]}\" has been updated"
  end
end

def load_file(file)
  output = File.read(File.join(data_path, file))
  case ext_name(file)
  when '.md'
    erb render_markdown(output)
  when '.txt'
    headers['Content-Type'] = 'text/plain'
    output
  when *IMAGE_TYPES
    headers['Content-Type'] = 'image/jpeg'
    output
  else
    output
  end
end

def basename(file)
  File.basename(file, '.*')
end

def ext_name(file)
  File.extname(file).downcase
end

def split_base_ext(filename)
  *base, ext = filename.split('.')
  [base.join('.'), ext]
end

def downcase_ext(filename)
  base, ext = split_base_ext(filename)
  base + '.' + ext.downcase
end

def append_next_num(filename)
  numbers = ('0'..'9')
  num = ''
  base, ext = split_base_ext(filename)
  base.reverse.each_char { |ch| numbers.cover?(ch) ? (num << ch) : break }
  new_num = (num.reverse.to_i + 1).to_s
  n = base[0, base.size - num.size]
  n + new_num + '.' + ext
end

def remove_and_cache_extension(file)
  session[:temp] = ext_name(file)
  basename(file)
end

helpers do
  def files_array
    Dir.glob(File.join(data_path, '*')).map { |path| File.basename(path) }
  end

  def render_markdown(content)
    markdown = Redcarpet::Markdown.new(Redcarpet::Render::HTML)
    markdown.render(content)
  end

  def image_file?(file)
    extension = ext_name(file)
    IMAGE_TYPES.any? { |type| extension == type }
  end

  def text_file?(file)
    extension = ext_name(file)
    TEXT_TYPES.any? { |t| t == extension }
  end

  def valid_type?(file)
    extension = ext_name(file)
    TEXT_TYPES.any? { |t| t == extension }
  end
end

get '/' do
  redirect '/index' if signed_in?
  erb :sign_in
end

post '/sign_out' do
  session[:username] = nil
  session[:password] = nil
  session[:success] = 'You have been signed out'
  redirect '/'
end

get '/sign_in_form' do
  erb :sign_in_form
end

post '/sign_in_form' do
  username = params[:username]
  password = params[:password]
  if valid_credentials?(username, password)
    session[:username] = username
    session[:success] = 'Welcome!'
    redirect '/index'
  else
    status 422
    session[:error] = 'Invalid Credentials'
    erb :sign_in_form
  end
end

get '/sign_up' do
  erb :sign_up
end

post '/sign_up' do
  password = params[:password]
  username = params[:username]
  credentials = load_user_credentials

  session[:error] = invalid_signup(username, password)
  redirect '/sign_up' if session[:error]

  bcrypt_pass = BCrypt::Password.create(password).to_s
  credentials[username] = bcrypt_pass

  File.open(credentials_path, 'w') { |f| YAML.dump(credentials, f) }
  session[:success] = "Thanks for signing up #{username}! Now you can sign in!"
  redirect 'sign_in_form'
end

get '/index' do
  redirect_if_signed_out
  @files = files_array
  erb :index
end

get '/new' do
  redirect_if_signed_out
  erb :new
end

post '/create' do
  redirect_if_signed_out

  filename = params[:filename]
  invalid_name = invalid_textfile(filename)
  if invalid_name
    session[:error] = invalid_name
    status 422
    erb :new
  else
    filename = downcase_ext(filename)
    file_path = File.join(data_path, filename)
    File.write(file_path, '')
    session[:success] = "\"#{filename}\" has been created!"
    redirect '/index'
  end
end

get '/:file/duplicate' do
  redirect_if_signed_out
  original = params[:file]
  session[:error] = no_file(original)
  redirect '/index' if session[:error]

  duplicate = basename(original) + '_copy' + File.extname(original)
  duplicate_path = File.join(data_path, duplicate)

  content = File.read(File.join(data_path, original))
  File.write(duplicate_path, content)

  session[:success] = "\"#{duplicate}\" has been created!"
  redirect '/index'
end

get '/upload' do
  redirect_if_signed_out
  erb :upload
end

post '/upload' do
  filename = downcase_ext(params['myfile'][:filename])
  filename = append_next_num(filename) while file_exists(filename)

  File.open('data/' + filename, 'w') do |f|
    f.write(File.open(params['myfile'][:tempfile]).read)
  end
  session[:success] = 'Your file has been uploaded successfully!'
  redirect '/index'
end

get '/:file/edit' do
  redirect_if_signed_out
  @filename = params[:file]
  session[:error] = invalid_edit
  redirect '/index' if session[:error]
  @content = File.read(File.join(data_path, @filename))
  session[:temp] = @content
  erb :edit
end

post '/:filename' do
  redirect_if_signed_out
  file_path = File.join(data_path, params[:filename])
  File.write(file_path, params[:content])
  session[:success] = check_file_edit
  redirect '/index'
end

get '/:file' do
  redirect_if_signed_out
  file = params[:file]
  session[:error] = no_file(file)
  redirect '/index' if session[:error]

  load_file(file)
end

post '/:filename/delete' do
  redirect_if_signed_out
  file_path = File.join(data_path, params[:filename])
  File.delete(file_path)
  session[:success] = "\"#{params[:filename]}\" has been deleted"
  redirect '/index'
end

get '/:filename/rename' do
  redirect_if_signed_out
  file = downcase_ext(params[:filename])
  @filename = remove_and_cache_extension(file)
  @extension = session[:temp]
  erb :rename
end

post '/:filename/rename' do
  redirect_if_signed_out

  old_filename = params[:filename] + session[:temp].to_s
  new_filename = params[:title] + session[:temp].to_s
  session[:temp] = nil

  session[:error] = invalid_rename(params[:title])
  redirect "/#{old_filename}/rename" if session[:error]

  old_file = File.join(data_path, old_filename)
  new_file = File.join(data_path, new_filename)

  File.rename(old_file, new_file)
  session[:success] = "\"#{old_filename}\" is renamed to \"#{new_filename}\""
  redirect '/index'
end
