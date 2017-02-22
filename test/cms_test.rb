require 'simplecov'
SimpleCov.start

ENV["RACK_ENV"] = "test"
require "minitest/autorun"
require "rack/test"
require "fileutils"
require_relative "../cms"
require 'tempfile'

class CMSTest < Minitest::Test
  include Rack::Test::Methods

  def app
    Sinatra::Application
  end

  def setup
    FileUtils.mkdir_p(data_path)
  end

  def teardown
    FileUtils.rm_rf(data_path)
  end

  def create_document(name, content = "")
    get "/index", {}, admin_session
    File.open(File.join(data_path, name), "w") { |file| file.write(content) }
  end

  def delete_user(username)
    credentials = load_user_credentials
    credentials.delete(username)
    File.open(credentials_path, 'w') { |f| YAML.dump(credentials, f) }
  end

  def admin_session
    { "rack.session" => { username: "tester" } }
  end

  def session
    last_request.env["rack.session"]
  end

  def test_index
    create_document "about.md"
    create_document "changes.txt"

    get "/index", {}, admin_session

    assert_equal 200, last_response.status
    assert_equal "text/html;charset=utf-8", last_response["Content-Type"]
    assert_includes last_response.body, "about.md"
    assert_includes last_response.body, "changes.txt"
  end

  def test_viewing_text_document
    create_document "history.txt", "Ruby 0.95 released"

    get "/history.txt"

    assert_equal 200, last_response.status
    assert_equal "text/plain", last_response["Content-Type"]
    assert_includes last_response.body, "Ruby 0.95 released"
  end

  def test_document_not_found
    get "/notafile.xtsd", {}, admin_session
    assert_equal 302, last_response.status
    assert_equal "\"notafile.xtsd\" does not exist.", session[:error]
  end

  def test_markdown
    create_document "about.md", "# Ruby is..." 

    get "/about.md"

    assert_equal 200, last_response.status
    assert_equal "text/html;charset=utf-8", last_response["Content-Type"]
    assert_includes last_response.body, "<h1>Ruby is...</h1>"
  end

  def test_editing_document
    create_document "edit_test.txt"

    get "/edit_test.txt/edit", {}, admin_session 

    assert_equal 200, last_response.status
    assert_includes last_response.body, %q(<button type="submit")
  end

  def test_updating_document
    post "/edit_test.txt", {content: "this is a test"}, admin_session

    assert_equal 302, last_response.status
    assert_equal "\"edit_test.txt\" has been updated", session[:success]

    get "/edit_test.txt"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "this is a test"
  end

  def return_to_index_unedited
    get "/edit_test.txt/edit"
    get "/index"
    get last_response["Location"]
    assert_equal "was unchaged", session[:success]
  end

  def test_new_document_view
    get "/new", {}, admin_session

    assert_equal 200, last_response.status
    assert_includes last_response.body, "for=\"filename\">Add"
  end

  def test_post_new_document
    post "/create", {filename: "test.txt"}, admin_session
    assert_equal 302, last_response.status
    assert_equal "\"test.txt\" has been created!", session[:success]

    get "/"
    get last_response["Location"]
    assert_includes last_response.body, "test.txt"
  end

  def test_create_file_without_name
    post "/create", {filename: ""}, admin_session
    assert_equal 422, last_response.status
    assert_includes last_response.body, "A name is required"
  end

  def test_file_with_invalid_extension
    post "/create", {filename: "noextension"}, admin_session
    assert_equal 422, last_response.status
    assert_includes last_response.body, "Your file name"
  end

  def test_file_with_invalid_chars
    post "/create", {filename: "//bad_characters"}, admin_session
    assert_equal 422, last_response.status
    assert_includes last_response.body, "may not include"
  end

  def test_file_delete
    create_document "delete_me.txt"
    post "/delete_me.txt/delete", {}, admin_session
    assert_equal 302, last_response.status
    assert_equal "\"delete_me.txt\" has been deleted", session[:success]

    get "/"
    refute_includes last_response.body, %q(href="/delete_me.txt")
  end

  def test_sign_in_with_good_credenials
    post "/sign_in_form", username: "tester", password: "password"
    assert_equal 302, last_response.status

    assert_equal "Welcome!", session[:success]
    assert_equal "tester", session[:username]

    get last_response["Location"]
    assert_includes last_response.body, "Signed in as"
    assert_equal 200, last_response.status  
  end

  def test_sign_in_with_bad_credentials
    post "/sign_in_form", username: "badname", password: "wrongpass"

    assert_equal 422, last_response.status
    assert_equal nil, session[:username]

    assert_includes last_response.body, "Invalid Credentials"
    assert_includes last_response.body, %q("username">Username:</label>)
  end

  def test_sign_out
    get "/index", {}, admin_session
    assert_equal 200, last_response.status
    assert_includes last_response.body, "Signed in as"

    post "/sign_out"
    assert_equal 302, last_response.status
    get last_response["Location"]

    assert_equal nil, session["username"]
    assert_includes last_response.body, "You have been signed out"
    assert_includes last_response.body, "Sign In"
  end

  def test_sign_up
    delete_user('bingbong')
    post '/sign_up', username: 'bingbong', password: 'passy'
    assert_equal 302, last_response.status
    assert_includes session[:success], 'Now you can sign'

    post '/sign_in_form', username: 'bingbong', password: 'passy'
    assert_equal 302, last_response.status
    assert_equal 'Welcome!', session[:success]
    get last_response['Location']
    assert_equal 200, last_response.status
    assert_includes last_response.body, 'Welcome'
  end

  def test_duplicate_file
    post "/create", {filename: "copy_this.txt"}, admin_session
    assert_equal 302, last_response.status
    assert_equal "\"copy_this.txt\" has been created!", session[:success]

    get "/copy_this.txt/duplicate"
    get last_response["Location"]
    assert_includes last_response.body, "copy_this_copy.txt"
  end

  def test_upload_image
    image = Tempfile.new(['concepts', '.jpg']) do |file|
      file.write(File.open('../data/concepts.jpg'))
    end
    post '/upload', 'myfile' => { filename: "image.jpg", tempfile: image.path }
    assert_equal 302, last_response.status
    assert_equal 'Your file has been uploaded successfully!', session[:success]
  end

  def test_invalid_filename
    post "/create", {filename: "good_name.txt"}, admin_session

    post '/good_name.txt/rename', {title: "/bad_characters" }
    get last_response["Location"]
    assert_includes last_response.body, "may not include"

    post '/good_name.txt/rename', {title: "" }
    get last_response["Location"]
    assert_includes last_response.body, "A name is required"
  end

  def test_rename_filename
    post "/create", {filename: "original_name.txt"}, admin_session

    post '/original_name.txt/rename', {title: "new_name.txt" }, admin_session
    assert_equal session[:success], "\"original_name.txt\" is renamed to \"new_name.txt\""
  end

  def test_rename_existing_filename
    post "/create", {filename: "original_name.txt"}, admin_session

    post '/original_name.txt/rename', {title: "original_name.txt" }, admin_session
    assert_equal session[:error], 'File name in use'
  end

  def test_format_downcase_ext
    post "/create", {filename: "big_ext.TXT"}, admin_session
    assert_equal session[:success], "\"big_ext.txt\" has been created!"
  end

  def test_increment_filename
    get '/index', {}, admin_session
    image = Tempfile.new(['concepts', '.jpg']) do |file|
      file.write(File.open('../data/concepts.jpg'))
    end
    post '/upload', 'myfile' => { filename: "9image10.jpg", tempfile: image.path }
    post '/upload', 'myfile' => { filename: "9image10.jpg", tempfile: image.path }
    post '/upload', 'myfile' => { filename: "9image10.jpg", tempfile: image.path }
    assert_equal 302, last_response.status
    assert_equal 'Your file has been uploaded successfully!', session[:success]
    get last_response["Location"]
    assert_includes last_response.body, "9image10.jpg"
    assert_includes last_response.body, "9image11.jpg"
    assert_includes last_response.body, "9image12.jpg"
  end

end