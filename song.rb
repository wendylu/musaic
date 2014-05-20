
require 'httparty'
require 'uri'
require 'active_record'
require 'rdio'
require 'rdio_consumer_credentials'
require 'csv'

class Song < ActiveRecord::Base
  has_many :scores
  has_many :songs, :through => :scores, :uniq => true

  has_and_belongs_to_many :playlist

  include HTTParty
  base_uri = 'ws.audioscrobbler.com'
  
  @@apikey = "82503bf7ee450de21d5f99fc18231afd"
  @@secret = "adbf6750fdfcf584ad1922d0ff01a661"
  @@echoNestApiKey = "IZFRJCU0ZQYNJVYLC" 
  @@gracenoteApiKey = "1584384-6E9B3B5099A5FCD0E6DC5807D5800F6E"
  @@gracenoteApiKey = "5917952-8542A5A1633EBA9A4BA98CB88105F396"
  @@gracenoteUserID = "261579841203371850-A1111C9E7D8DEA01504B1B0F229C4FB9"
  
  #for bulk load DB
  @@batch = []

  validates :trackKey, :uniqueness => true
  
  attr_accessible :title, :artist, :album, :trackKey, :artistKey, :albumKey, :danceability, :energy, :mode, :tags

  def initialize(title, artist, album, trackKey, artistKey, albumKey, danceability, energy, mode, tags)
    @title = title
    @artist = artist
    @album = album
    @trackKey = trackKey
    @artistKey = artistKey
    @albumKey = albumKey
    @danceability = danceability
    @energy = energy
    @mode = mode
    @tags = tags
  end

  # returns an array of songs below the given similarity score relative to the given song
  def getSimilarSongs(threshold)
    toReturn = []
    for song in Song.all
      if (song != self)
        similarity = self.getSimilarity(song)
        if (similarity < threshold)
          toReturn << song
        end
      end
    end
    return toReturn
  
  scores = []
  matchingEntries = Score.find(:all, :conditions => ["song1_id = ? AND similarity < ?", self.id, threshold.to_s])
  for score in matchingEntries
    if (!scores.include?(score) && score.song2 != self)
      scores << score
    end
  end
  
  matchingEntries = Score.find(:all, :conditions => ["song2_id = ? AND similarity < ?", self.id, threshold.to_s])
  for score in matchingEntries
    if (!scores.include?(score) && score.song1 != self)
      scores << score
    end
  end
  scores.sort! { |a,b| a.similarity <=> b.similarity}
  
  toReturn = []
  for s in scores.take(250)
    if (s.song1 == self)
      toReturn << s.song2
    else
      toReturn << s.song1
    end
  end
  
  return toReturn
  end
  
  # returns a similarity measure between 0 and 10 (0 is most similar)
  def getSimilarity(song)
    if (song == self)
      raise "can't get similarity of same song!"
    end
  
    cachedScore = ActiveRecord::Base.connection.select_all("Select * FROM scores WHERE (song1_id = #{self.id} AND song2_id = #{song.id})")
    if (cachedScore.length > 0)
      #puts "cache hit! similarity score"
      return cachedScore[0]["similarity"].to_f
    end
    
    cachedScore = ActiveRecord::Base.connection.select_all("Select * FROM scores WHERE (song2_id = #{self.id} AND song1_id = #{song.id})")
    if (cachedScore.length > 0)
      #puts "cache hit! similarity score"
      return cachedScore[0]["similarity"].to_f
    else
      return 10 #if it's not cached, the similarity cannot be less than 6
      #Weights must add to 1!!
      tagsWeight = 0.5
      danceWeight = 0.2
      energyWeight = 0.2
      modeWeight = 0.0
      artistWeight = 0.1
    
      tagsSim = self.getTagsSimilarity(song, true)
      danceSim = self.getEchoNestSimilarity(song, "danceability", true)
      energySim = self.getEchoNestSimilarity(song, "energy", true)
      modeSim = self.getEchoNestSimilarity(song, "mode", true)
      artistSim = 0
      if (self.artist == song.artist)
        then artistSim = 10
      end
    
      score = 10 - ((tagsWeight * tagsSim) + (danceWeight * danceSim) + (energyWeight * energySim) + (modeWeight * modeSim) + (artistWeight * artistSim))
      
      #cache the similarity score
      
      ActiveRecord::Base.connection.execute("INSERT INTO scores (song1_id, song2_id, similarity) VALUES (#{self.id}, #{song.id}, #{score.round(3)})")
      ActiveRecord::Base.connection.execute("INSERT INTO scores (song1_id, song2_id, similarity) VALUES (#{song.id}, #{self.id}, #{score.round(3)})")
 
      return score
    end
  end
  
  # Run Song.loadDB from rails console to populate the *existing* songs in the Song table with metrics from the APIs. 
  # Safe to call when table is partially loaded
  def self.loadDB
    for song in Song.all
      if (song.danceability == nil || song.tags == nil || song.tags = "")
        #puts song.title
        song.setAttributesInDB
        sleep 3
      end
    end
  end
  
  def self.manualAddSong(title, artist)
     x = Song.addSongToDB(title, artist)

      if (x) #song added successfully
        sims = x.getLastFMSimilar
        if (sims)
          for simSong in sims
            storedSong = Song.find(:all, :conditions => {:title => simSong.title.downcase, :artist => simSong.artist.downcase})[0]
            if (storedSong)
              loadSimilarityScore(x, storedSong, 1.5)
            end
          end
        end
        
        for song in Song.all
          loadSimilarityScore(x, song)
        end
      end
  end
  
  
  # NOT READY!! Don't Run Song.addMoreSongs from rails console to load *new* song entries into the database
  def self.addMoreSongsToDB
    for song in Song.all
      if (song.id > 278 && song.id < 500)
        sims = song.getLastFMSimilar
        existingSims = song.getSimilarSongs(4)
        
        if (sims)
          #reset the start index
          #startIndex = 0
          recentlyAdded = []
          
          for simSong in sims
            puts simSong.title
            
            begin
              x = Song.addSongToDB(simSong.title, simSong.artist)
              #if (startIndex == 0 && x)
              #  startIndex = x
              #end
              if (x) #song added successfully
                puts "existing songs"
                for existingSong in existingSims
                  loadSimilarityScore(x, existingSong) 
                end
                puts "seed song"
                loadSimilarityScore(x, song, 1.5) 
                puts "recently added songs"
                for a in recentlyAdded
                  aEntry = Song.find(:all, :conditions => {:title => a.title, :artist => a.artist})
                  if (aEntry.length > 0)
                    loadSimilarityScore(x, aEntry[0], 1.5) 
                  end
                end
                recentlyAdded << x
                puts "recently added count" + recentlyAdded.count.to_s
              end 
            rescue
              puts "problem adding song"
            end
          
            sleep 3
          end
        end
      end
    end
  end
  
  #Private methods
  
  #returns a similarity measure between 0 and 10 (10 is most similar) based on LastFM Top Tags intersection. connect - connect to API? if not just searches db
  def getTagsSimilarity(song, connect)
    if (self == song)
      raise "can't get tags similarity of same song!"
    end
    
    tagNames1 = self.getTags(connect)
    tagNames2 = song.getTags(connect)
    
    if (tagNames1 == nil || tagNames2 == nil)
      return 0
    end
    
    numTags = 0.0
    if (tagNames1.count > tagNames2.count)
      numTags = tagNames2.count
    else
      numTags = tagNames1.count
    end
    
    if (numTags == 0.0)
      return 0
    end
    
    #puts 10 * (tagNames1 & tagNames2).size.to_f / numTags    
    return 10 * (tagNames1 & tagNames2).size.to_f / numTags    
  end
  
  def getTags(connect)
    begin
      
      tagNames1 = Set.new
    
      if (self.tags != nil)
        #puts "tag cache hit!"
        text = self.tags.split(/,/)
        for x in text
          tagNames1.add(x)
        end
        return tagNames1
      end
    
      if (connect)
        options1 = { :query => {:method => "track.gettoptags", :artist => self.artist, :track => self.title, :api_key => @@apikey,}}
        response1 = HTTParty.get(URI.encode("http://ws.audioscrobbler.com/2.0/"), options1)
    
        if (response1 == nil || response1["lfm"] == nil || response1["lfm"]["toptags"] == nil)
          then return nil
        end
    
        tags1 = response1["lfm"]["toptags"]["tag"]
    
        if (tags1 == nil)
          then return nil
        end
    
        tags1 = tags1.select { |tag| tag["count"].to_i > 1}

        if (tags1 == nil)
          then return nil
        end

        tagString = ""
        for tag in tags1
          tagNames1.add(tag["name"])
          tagString << tag["name"]
          tagString << ","
        end
    
        if (tagString == "")
          self.tags = nil
        else 
          self.tags = tagString
        end
        self.save()
      end
      
      return tagNames1
    
    rescue
      return nil
    end
    
  end
  
  def getAttribute(attribute, connect)
    if (attribute == "danceability" && self.danceability != nil) 
      #puts "cache hit! danceability"
      return self.danceability
    end 
    if (attribute == "energy" && self.energy != nil) 
        #puts "cache hit! energy " + self.energy.to_s
        return self.energy
    end
    if (attribute == "mode" && self.mode != nil) 
          #puts "cache hit! mode"
          return self.mode
    end
    
    options1 = { :query => {:api_key => @@echoNestApiKey, :artist => self.artist, :title => self.title}}
    begin
      if (connect)
        response1 = HTTParty.get(URI.encode("http://developer.echonest.com/api/v4/song/search"), options1)
    
        if (response1["response"]["songs"] == nil || response1["response"]["songs"][0] == nil)
          puts "song not found"
          return nil
        end
    
        songId1 = response1["response"]["songs"][0]["id"]
    
        if (songId1 == nil)
          puts "song not found"
          return nil
        end
    
        options1 = { :query => {:api_key => @@echoNestApiKey, :id => songId1, :bucket => "audio_summary"}}
        response1 = HTTParty.get(URI.encode("http://developer.echonest.com/api/v4/song/profile"), options1)
      
        #cache new value
        if (response1["response"]["songs"] == nil || response1["response"]["songs"][0] == nil)
          return nil
        end
      
        value = response1["response"]["songs"][0]["audio_summary"][attribute]
         if (attribute == "danceability" && self.danceability == nil) 
            self.danceability = value
            #puts "saved into cache-danceability"
          end 
          if (attribute == "energy" && self.energy == nil) 
             self.energy = value
              #puts "saved into cache-energy"
          end
          if (attribute == "mode" && self.mode == nil) 
              self.mode = value
          end
          self.save()
        
        return response1["response"]["songs"][0]["audio_summary"][attribute]
      else
        return nil
      end
    
    rescue
      return nil
    end
  end
  
  #returns a similarity measure between 0 and 10 (10 is most similar) based on EchoNest measure for the attribute given
  def getEchoNestSimilarity(song, attribute, connect)
    if (self == song)
      raise "can't get tags similarity of same song!"
    end
    
    song1 = self.getAttribute(attribute, connect)
    song2 = song.getAttribute(attribute, connect)

    if (song1 == nil || song2 == nil)
      return 0
    end
    
    #puts attribute + song1.to_s + " " + song2.to_s
    #puts 10 * (1 - (song1 - song2).abs)
    return 10 * (1 - (song1 - song2).abs)
  end
  
  def getGraceNoteSimilarity(song, attribute)
    self.registerGraceNote(@@gracenoteApiKey)
    

    xml = %Q|<QUERIES>
          <LANG>eng</LANG>
          <AUTH>
            <CLIENT>#{@@gracenoteApiKey}</CLIENT>
            <USER>#{@user_id}</USER>
          </AUTH>
          <QUERY CMD="ALBUM_SEARCH">
            <TEXT TYPE="ARTIST">#{song.artist}</TEXT>
            <TEXT TYPE="ALBUM_TITLE">#{song.album}</TEXT>
            <TEXT TYPE="TRACK_TITLE">#{song.title}</TEXT>
          </QUERY>
        </QUERIES>|
    
    puts xml
    response1 = HTTParty.post(base_url(@@gracenoteApiKey), :body => xml, :headers => {'Content-type' => 'text/xml'})
  end
  
  def base_url(client_id)
      "https://c#{client_id.split('-').first}.web.cddbp.net/webapi/xml/1.0/"
  end
  
  def getLastFMSimilar
    options1 = { :query => {:method => "track.getsimilar", :artist => self.artist, :track => self.title, :api_key => @@apikey,}}
    response1 = HTTParty.get(URI.encode("http://ws.audioscrobbler.com/2.0/"), options1)
    
    if (response1 == nil || response1["lfm"] == nil || response1["lfm"]["similartracks"] == nil || response1["lfm"]["similartracks"]["track"].is_a?(String))
      then return nil
    end
    
    response1["lfm"]["similartracks"]["track"].shift
    
    toReturn = []
    for track in response1["lfm"]["similartracks"]["track"]
      #don't set album for now because album info is not contained in the response and individually getting each album from the track takes a LONG time 
      album = nil

      song = Song.new()
      song.title = track["name"]
      song.artist = track["artist"]["name"]
      song.album = album
      toReturn << song
    end
    
    return toReturn
  end
  
  def setAttributesInDB
    #Now load tags   
  begin
    options1 = { :query => {:method => "track.gettoptags", :artist => self.artist, :track => self.title, :api_key => @@apikey,}}
    response1 = HTTParty.get(URI.encode("http://ws.audioscrobbler.com/2.0/"), options1)
    
    if (response1["lfm"]["toptags"] == nil)
      puts "song not found on lastFM" + self.title + " " + self.artist
    end
    
    tags1 = response1["lfm"]["toptags"]["tag"]
    
    if (tags1 == nil)
      puts "no tags found on lastFM" + self.title + " " + self.artist
    end
    
    tags1 = tags1.select { |tag| tag["count"].to_i > 1}

    if (tags1 == nil)
      puts "no tags over count 1 found on lastFM" + self.title + " " + self.artist
    end

    tagNames1 = ""
    
    for tag in tags1
      tagNames1 << tag["name"]
      tagNames1 << ","
    end
    
    if (tagNames1 == "") 
      self.tags = nil
    else 
      self.tags = tagNames1
    end
    self.save()
  rescue

  end
  
  #Set EchoNest attributes
  begin
    options1 = { :query => {:api_key => @@echoNestApiKey, :artist => self.artist, :title => self.title}}
   
    response1 = HTTParty.get(URI.encode("http://developer.echonest.com/api/v4/song/search"), options1)

    if (response1["response"]["songs"] == nil || response1["response"]["songs"][0] == nil)
      puts "this song not found on echonest " + self.title + " " + self.artist
    end
   
    songId1 = response1["response"]["songs"][0]["id"]
    
    if (songId1 == nil)
      puts "song not found on echonest " + self.title + " " + self.artist
    end
    
    options1 = { :query => {:api_key => @@echoNestApiKey, :id => songId1, :bucket => "audio_summary"}}
   
    response1 = HTTParty.get(URI.encode("http://developer.echonest.com/api/v4/song/profile"), options1)
    
    if (response1["response"]["songs"] == nil || response1["response"]["songs"][0] == nil)
      puts "summary not found on echonest" + self.title + " " + self.artist
    end
    
    self.danceability = response1["response"]["songs"][0]["audio_summary"]["danceability"].to_f.round(3)
    self.energy = response1["response"]["songs"][0]["audio_summary"]["energy"].to_f.round(3)
    self.mode = response1["response"]["songs"][0]["audio_summary"]["mode"].to_f
    self.save()
  rescue
    
  end
    
  end

  # Run Song.loadDB from rails console to populate the Song table with metrics from the APIs. 
  # Safe to call when table is partially loaded
  def self.loadDB
    for song in Song.all
      if (song.danceability == nil || song.tags == nil || song.tags = "")
        song.setAttributesInDB
        sleep 2
      end
    end
  end


# Rdio API Calls

  @@rdioApiKey = "GAlNi78J_____zlyYWs5ZG0\
2N2pkaHlhcWsyOWJtYjkyN2xvY2FsaG9zdEbwl7EHvby\
lWSWFWYMZwfc="
  @@domain = "localhost"
  @@rdioBaseUrl = "http://api.rdio.com/1/\
"
  @@rdio = Rdio.new([RDIO_CONSUMER_KEY, RDIO_CONSUMER_SECRET])


# given a song title and artist, searches echonest api and gets
# rdio foreign id (track id) for the song
# then calls Rdio API to get track object related to this track key

  def self.getRdioTrack(title, artist)
     options = { :query => {:api_key => @@echoNestApiKey, :artist => artist, :title => title, :format => "json", "bucket" => "tracks", :bucket => "id:rdio-US", :limit => true, :results => 1}}

     response = HTTParty.get(URI.encode("http://developer.echonest.com/api/v4/song/search"), options)["response"]

     if response["songs"] != nil then
     	song_match = response["songs"]
	
	 	if song_match.count > 0 then
	   		full_track_id = song_match[0]["tracks"][0]["foreign_id"]
	   		track_id = full_track_id.sub("rdio-US:track:", "")
	   		rdio_response = @@rdio.call('get', {:keys => track_id})["result"]

	   		if rdio_response != nil then
	      		track_object = rdio_response[track_id]
	      		return {:song => track_object, :error => nil}
	   		end
	   	else
	   		return {:song => nil, :error => "No matching song found."}
    	end
	else
		error_message = " unknown api call error. Likely exceeded # of allowable requests in a minute."
		if (response["status"] != nil) then
			error_message = response["status"]["message"]
		end
		
		return {:song => nil, :error => "API Call Error: "+ error_message}
	end
  end

# returns the id of the newly added song, or nil if song was not added 
  def self.addSongToDB(title, artist)
	top_match = getRdioTrack(title, artist)
	if (top_match[:song] != nil) then
		if (Song.find(:all, :conditions => {:trackKey => top_match[:song]['key']}).length == 0)
    		song = Song.new
			  song.title = top_match[:song]['name'].downcase
        	song.artist = top_match[:song]['artist'].downcase
       		song.album = top_match[:song]['album'].downcase
        	song.trackKey = top_match[:song]['key'].downcase
        	song.artistKey = top_match[:song]['artistKey'].downcase
        	song.albumKey = top_match[:song]['albumKey'].downcase
        	song.save(:validate => false)
			
			# adds danceability and other similarity
			# related attributes to the database
			puts "Setting attribute"
	        song.setAttributesInDB	
	        return song
        	#puts "Song added to DB => Title = " + song.title + " Artist = " + song.artist + " Album = " + song.album
        else
          puts "Song already in database."
          return nil
        end
	else
	  puts "NO Rdio match" 
	  return nil
	end   
  end
  
  def self.nilOut
    for song in Song.all
      if (song.tags == "")
        song.tags = nil
        song.save
      end
    end
  end
  
  def self.loadSimilarityScore(song, song2, *boost)
    if (song2 != song)
      cachedScore = ActiveRecord::Base.connection.select_all("Select * FROM scores WHERE (song1_id = #{song.id} AND song2_id = #{song2.id})")
      if (cachedScore.length == 0)
        cachedScore = ActiveRecord::Base.connection.select_all("Select * FROM scores WHERE (song2_id = #{song.id} AND song1_id = #{song2.id})")
        if (cachedScore.length == 0)
          #Weights must add to 1!!
          tagsWeight = 0.5
          danceWeight = 0.2
          energyWeight = 0.2
          modeWeight = 0.0
          artistWeight = 0.1

          tagsSim = song.getTagsSimilarity(song2, false)
          danceSim = song.getEchoNestSimilarity(song2, "danceability", false)
          energySim = song.getEchoNestSimilarity(song2, "energy", false)
          modeSim = song.getEchoNestSimilarity(song2, "mode", false)
          artistSim = 0
          if (song.artist == song2.artist)
            then artistSim = 10
          end

          score = 10 - ((tagsWeight * tagsSim) + (danceWeight * danceSim) + (energyWeight * energySim) + (modeWeight * modeSim) + (artistWeight * artistSim))

          for b in boost
            score = score - b
          end
          
          if (score <= 6)
            #store similarity score for bulk load into cache
            @@batch.push "#{song.id}, #{song2.id}, #{score.round(3)}"
            @@batch.push "#{song2.id}, #{song.id}, #{score.round(3)}"
          
            firstEntry = @@batch[0].split(/, /)
            #puts firstEntry
            @@batch.shift
            q = "INSERT INTO scores (song1_id, song2_id, similarity) SELECT #{firstEntry[0]} AS song1_id, #{firstEntry[1]} AS song2_id, #{firstEntry[2]} AS similarity UNION SELECT "
            q << @@batch.join(" UNION SELECT ")
            ActiveRecord::Base.connection.execute(q)

            @@batch = []
          end
        end
      end
    end
  end
  
  def self.loadSimilarityTable
    @@batch = []
    count = 0
    for song in Song.all
      if (song.id > 3000)
        for song2 in Song.all
          loadSimilarityScore(song, song2)
        end
      end
    end
  end
  
  def self.manualAddAll
    csv_text = File.read('manual.csv')
    csv = CSV.parse(csv_text, :headers => true)
    csv.each do |row|
      Song.manualAddSong(row['title'], row['artist'])
      sleep 6
    end
  end

  # Run Song.removeDups to remove songs that have the same title and artist
  def self.removeDups
    songsWithDups = Song.select("id, title, artist, count(title) as quantity").group(:title, :artist).having("quantity > 1")
    for x in songsWithDups
      for score in Score.find(:all, :conditions => {:song1_id => x.id})
        score.destroy
      end
      
      for score in Score.find(:all, :conditions => {:song2_id => x.id})
        score.destroy
      end
      x.destroy
    end
  end
    
   def self.cacheGraphs
    for song in Song.all
      cachedGraph = Graph.find_by_song_id(song.id)
      if (!cachedGraph) #no cache found
        graph = Graph.new()
        graph.song = song
      end
    end
  end
  
end

