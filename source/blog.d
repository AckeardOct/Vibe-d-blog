module blog;

import std.stdio;
import std.datetime;
import std.algorithm;
import std.container.rbtree;

import vibe.d;
import vibe.data.bson;
import vibe.data.json;
import vibe.db.mongo.mongo;

immutable string DB_IP = "127.0.0.1";

class Post{	
    BsonObjectID id;
    BsonDate date;    
    string title;
    string text;
    string[] tags;    

	this(Bson _bson){		
		//writeln("Type: ", _bson["_id"].type());
		id = _bson["_id"].get!BsonObjectID;
		date = currentDate();
		title = _bson["title"].get!string;
		text = _bson["text"].get!string;

		auto set = redBlackTree!string;
		string[] tmp;
		foreach(Bson tag; _bson["tags"]){
			tmp ~= tag.get!string[];
			foreach(string str; tmp)
				set.insert(str);
		}
		foreach(string str; set)
			tags ~= str;
	}
}

BsonDate currentDate(){
	return BsonDate(Clock.currTime().toUnixTime());
}   

Json toJson(ref string[] _ar){
	Json[] ar;
	foreach(str; _ar){
		if(str.length > 1)
			ar ~= Json(str);	
	}
	return Json(ar);
}

struct BlogReq{
	Bson condition;
	uint page;
}

BlogReq getBson(HTTPServerRequest _req){
	BlogReq ret;	
	ret.condition = Bson.emptyObject;
	if(_req.params.length()){
		string id = _req.params.get("id");
		if(!id.empty())
			ret.condition["_id"] = BsonObjectID.fromString(id);
		string tag = _req.params.get("tag");
		if(!tag.empty())
			ret.condition["tags"] = tag;				
		ret.page = to!uint(_req.params.get("page"));					
	}		
	return ret;
}

void clearSpaces(ref string[] _ar){
	foreach(ref str; _ar){
		foreach(i, a; str){
			if(a == ' '){
				str = str[i + 1 .. $];
				break;
			}
		}
		foreach_reverse(i, a; str){
			if(a == ' '){
				str = str[0 .. i];
				break;
			}
		}
	}
}

class Blog{
private:
	Db db;

public:	
	this(){	
		db = new Db;
		auto router = new URLRouter;
		with(router){
			get("*", serveStaticFiles("public/"));
			get("/", &pageIndex);
			get("/index/:page", &pageIndex);
			get("/post/:id", &pageIndex);
			get("/tag/:tag", &pageIndex);
			get("/admin", &pageAdmin);
			get("/admin/:id", &pageAdmin);
			get("/admin/tag/:tag", &pageAdmin);
			get("/create", &pageCreate);				
			post("/created", &eventCreate);				
			get("/remove/:id", &eventRemove);			
			get("/edit/:id", &pageEdit);
			post("/edit/:id", &eventEdit);
		}

		auto settings = new HTTPServerSettings;
		with(settings){
			port = 8080;
			bindAddresses = ["::1", "127.0.0.1"];
		}
  		listenHTTP(settings, router);
  		logInfo("Please open http://127.0.0.1:8080/ in your browser.");  
	}

	void pageIndex(HTTPServerRequest _req, HTTPServerResponse _res){
		Post[] posts = db.getPosts(getBson(_req));				
		string[] allTags = db.getAllTags();
		string searchTag = _req.params.get("tag");
    	render!("layout.dt", posts, searchTag, allTags)(_res);
	}

	void pageAdmin(HTTPServerRequest _req, HTTPServerResponse _res){
		Post[] posts = db.getPosts(getBson(_req));
		string[] allTags = db.getAllTags();		
		string searchTag;
    	render!("admin.dt", posts, searchTag, allTags)(_res);
	}	

	void pageCreate(HTTPServerRequest _req, HTTPServerResponse _res){
		string action = "/created";
		string title = "title";
		string tags = "tag1; tag2";
		string text = "Enter your Text";			
		string[] allTags = db.getAllTags();
		string searchTag;
    	render!("create.dt", action, title, tags, text, searchTag, allTags)(_res);
	}

	void pageEdit(HTTPServerRequest _req, HTTPServerResponse _res){		
		string action = "";
		string title;
		string tags;
		string text;
		Post[] posts = db.getPosts(getBson(_req));		
		action ~= posts[0].id.toString();
		if(posts.length){
			title = posts[0].title;
			text  = posts[0].text;
			foreach(i, tag; posts[0].tags){
				tags ~= tag;
				if(i != posts[0].tags.length)
					tags ~="; ";
			}
		}
		string[] allTags = db.getAllTags();
		string searchTag;
    	render!("create.dt", action, title, tags, text, searchTag, allTags)(_res);
	}

	void eventCreate(HTTPServerRequest _req, HTTPServerResponse _res){
		auto form = &_req.form;
		Bson b = Bson.emptyObject;
		b["title"] = form.get("postTitle");
		b["text"]  = form.get("postText");
		string[] tags = form.get("postTags").split(";");
		tags.clearSpaces();
		b["tags"]  = tags.toJson();
		b["date"]  = currentDate();
		db.insert(b);

		pageAdmin(_req, _res);
	}

	void eventRemove(HTTPServerRequest _req, HTTPServerResponse _res){
		db.remove(getBson(_req));
		Post[] posts = db.getPosts();
		string[] allTags = db.getAllTags();	
		string searchTag;	
    	render!("admin.dt", posts, searchTag, allTags)(_res);
	}

	void eventEdit(HTTPServerRequest _req, HTTPServerResponse _res){				
		Bson condition = Bson.emptyObject;	
		if(_req.params.length()){
			BsonObjectID id = BsonObjectID.fromString(_req.params.get("id"));
			condition["_id"] = id;		
		}
		Bson set = Bson.emptyObject;
		if(_req.form.length()){
			set["title"] = _req.form.get("postTitle");
			string[] tags = _req.form.get("postTags").split(";");
			tags.clearSpaces();
			set["tags"]  = tags.toJson();
			set["text"]  = _req.form.get("postText");
		}		
		Bson update = Bson.emptyObject;
		update["$set"] = set;
		db.update(condition, update);

		Post[] posts = db.getPosts(getBson(_req));
		string[] allTags = db.getAllTags();		
		string searchTag;
    	render!("admin.dt", posts, searchTag, allTags)(_res);
	}
}

class Db{
	MongoClient client;
	MongoCollection coll;

	this(){
		client = connectMongoDB(DB_IP);		
		coll = client.getCollection("test.posts");
	}

	Post[] getPosts(){
		BlogReq req;
		req.page = 0;
		return getPosts(req);
	}

	Post[] getPosts(BlogReq _req){
		Post[] ret;
		uint limit = 3;		
		foreach(Bson doc; coll.aggregate([ "$match" : _req.condition ], [ "$skip" : _req.page * limit ], [ "$limit" : limit ])  /*coll.find(_req.condition)*/)
			ret ~= new Post(doc);
		return ret;
	}

	string[] getAllTags(){
		string[] ret;
		auto set = redBlackTree!string;
		Bson condition = Bson.emptyObject;
		condition["_id"] = false;
		condition["tags"] = true;		
		foreach(Bson doc; coll.find(Bson.emptyObject, condition))			
			foreach(str; doc["tags"])				
				set.insert(str.get!string);		
		foreach(string str; set)
			ret ~= str;	
		return ret;		
	}

	void insert(Bson _bson){
		coll.insert(_bson);
	}

	void remove(BlogReq _req){
		coll.remove(_req.condition);
	}

	void update(Bson _condition, Bson _set){
		coll.update(_condition, _set); 	
	}
}