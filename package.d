module wikidata;

// (C) 2018-2021 by Matthias Rossmy
// This file is distributed under the "Fair Use License v2"

/* Example
class GeoObject : WdObject
{
	@WikiDataProp("?itemDescription") string desc;
}
class DatePopulation
{
	@WikiDataProp("point in time") string date;
	@WikiDataProp("population") string population;
}

auto results = WikiData.find("geographic region","Springfield").getList!GeoObject;

foreach(obj;results)
{		
	auto history = obj.query("population").sortAsc("date").getList!DatePopulation;
	if(history.length>0)
	{
		writeln("Wikidata Object: ",obj.id);
		writeln("Description: ",obj.desc);
		foreach(item;history)
		{
			writeln(item.date," ",item.population);
		}
	}
}
*/

public import std.xml;

import std.stdio;
import std.net.curl;
import std.uri;
import std.path;
import std.traits;
import std.conv;
import std.ascii;
import std.string;

import easyd.base;

string bindingName(Element e)
{
	try
	{
		return e.tag.attr["name"];
	}
	catch(Exception e)
	{
		return "";
	}
}

string bindingValue(Element e)
{
	foreach(value;e.elements) return value.text;
	return "";
}

class WikiData
{
	static string dataLang="en"; //language for the name parameter of the find function and for all data returned by Wikidata
	static string codingLang="en"; //language for properties, units, categories...
	
	static bool verbose=false;
	private static string[string] propCache;
	private static string[string] unitCache;
	private static string[string] catCache;
	
	static bool isNativeID(string name)
	{
		return name.length>=2 && name[0].isUpper && name[1..$].isNumeric;
	}
	
	static string propID(string name)
	{
		if(isNativeID(name)) return name;
		auto cacheResult = (name in propCache);
		if(cacheResult !is null) return *cacheResult;
		
		auto resultList = find("Q18616576",name).getList(codingLang);
		if(resultList.length==0) throw new Exception("Property "~name~" does not exist");
		auto result = resultList[0].id;
		propCache[name] = result;
		return result;
	}
	
	static string unitID(string name)
	{
		if(isNativeID(name)) return name;
		auto cacheResult = (name in unitCache);
		if(cacheResult !is null) return *cacheResult;
		
		auto resultList = find("Q47574",name).getList(codingLang);
		if(resultList.length==0) throw new Exception("Unit "~name~" does not exist");
		auto result = resultList[0].id;
		unitCache[name] = result;
		return result;
	}
	
	static string name2IdList(string name, string category="")
	{
		auto cacheResult = (name in catCache);
		if(cacheResult !is null) return *cacheResult;
		
		auto resultList = find(category,name).getList(codingLang);
		if(resultList.length==0) throw new Exception(name~" does not exist");
		string result;
		foreach(item;resultList) result ~= ("(wd:"~item.id~")");
		catCache[name] = result;
		return result;
	}
	
	static Element rawQuery(string sparql)
	{
		try
		{
			if(verbose) writeln(sparql);
			auto reply = get("https://query.wikidata.org/sparql?query="~std.uri.encode(sparql)).idup;
			if(verbose) writeln(reply);
			auto d = new Document(reply);
			foreach(item;d.elements) if(item.tag.name=="results") return item;
			if(verbose) writeln("No result");
			return null;
		}
		catch(Exception e)		
		{
			if(verbose) writeln(e.msg);
			return null;
		}
	}
	
	static class Query
	{
		string[] filters;
		string nameFilter;
		bool nameFilterCase;
		bool nameFilterExact;
		string bindings;
		string analyzeVar="item";
		string analyzeProp;
		string[string] binding2member;
		string postfix;
		
		Query isPartOf(string what)
		{
			if(isNativeID(what))
			{
				filters ~= ("?item wdt:P361 wd:"~what);
			}else{
				filters ~= ("VALUES (?partOf) { "~name2IdList(what)~" }");
				filters ~= "?item wdt:P361 ?partOf";
			}
			return this;
		}
		
		/*Query where(string prop, string value) //TODO: diese Funktion mit dem cities-Beispiel funktionsfähig machen
		{
			auto pid = propID(prop);
			if(isNativeID(value))
			{
				filters ~= ("?item wdt:"~pid~" wd:"~value);
			}else{
				filters ~= ("VALUES (?partOf) { "~name2IdList(value,prop)~" }");
				filters ~= "?item wdt:"~pid~" ?partOf";
			}
			return this;
		}*/
		
		Query bind(string name)
		{
			if(name[0]!='?') name = "?"~name;
			bindings ~= (name~" ");
			return this;
		}
		
		Query bind(string prop, string bindTo)
		{
			prop = WikiData.propID(prop);
			if(analyzeVar=="item")
			{
				filters ~= ("?"~analyzeVar~" wdt:"~prop~" ?"~bindTo);
			}else{
				if(prop==analyzeProp)
				{
					filters ~= ("?"~analyzeVar~" ps:"~prop~" ?"~bindTo);
				}else{
					filters ~= ("?"~analyzeVar~" pq:"~prop~" ?"~bindTo);
				}
			}
			return bind(bindTo~"Label");
		}
		
		Query bind(string prop, string unit, string bindTo)
		{
			prop = WikiData.propID(prop);
			unit = WikiData.unitID(unit);
			if(analyzeVar=="item")
			{
				filters ~= ("?"~analyzeVar~" p:"~prop~"/psv:"~prop~" [ wikibase:quantityAmount ?"~bindTo~"; wikibase:quantityUnit wd:"~unit~"; ]");
			}else{
				throw new Exception("Filtering sub-properties by unit is not implemented yet");
			}
			return bind(bindTo~"Label");
		}
		
		private void bindHelper(T2)(T2 obj)
		{
			//writeln("BindHelper for ",typeid(T2).to!string);
			foreach (i,m; obj.tupleof)
			{
				//writeln("  Member ",__traits(identifier, obj.tupleof[i]));
				static if(hasUDA!(obj.tupleof[i], WikiDataProp))
				{
					auto prop = getUDAs!(obj.tupleof[i], WikiDataProp)[0].prop;
					auto unit = getUDAs!(obj.tupleof[i], WikiDataProp)[0].unit;
					if(verbose) writeln("Auto-bind ",prop);
					if(prop[0]=='?')
					{
						bind(prop);
						binding2member[prop[1..$]] = __traits(identifier, obj.tupleof[i]);
					}else{
						if(unit=="")
						{
							bind(prop,__traits(identifier, obj.tupleof[i]));
						}else{
							bind(prop,unit,__traits(identifier, obj.tupleof[i]));
						}
						binding2member[__traits(identifier, obj.tupleof[i])~"Label"] = __traits(identifier, obj.tupleof[i]);
					}
				}
			}
		}
		
		Query sortAsc(string var)
		{
			postfix ~= "ORDER BY ASC(?"~var~") ";
			return this;
		}
		
		Query sortDesc(string var)
		{
			postfix ~= "ORDER BY DESC(?"~var~") ";
			return this;
		}
		
		Element getXml(T=WdObject)(string dataLanguage="")
		{
			if(dataLanguage=="") dataLanguage=dataLang;
			if(nameFilter!="")
			{
				if(nameFilterCase)
				{
					filters ~= ("?item ?label \""~nameFilter~"\"@"~dataLanguage);
					if(nameFilterExact)
					{
						filters ~= "?item rdfs:label ?name";
						filters ~= ("FILTER regex(?name, \"^"~nameFilter~"$\")");
					}
				}else{
					filters ~= "?item rdfs:label ?name";
					if(nameFilterExact)
					{
						filters ~= ("FILTER regex(?name, \"^"~nameFilter~"$\", \"i\")");
					}else{
						filters ~= ("FILTER regex(?name, \""~nameFilter~"\", \"i\")");
					}
				}
				nameFilter="";
			}
			
			auto querystr = "SELECT REDUCED ";
			static if(is(T:WdObject))
			{
				querystr ~= "?item ";
			}
			
			auto dummy = new T;
			foreach(t; BaseClassesTuple!(Unqual!T))
			{
				bindHelper(cast(t)(dummy));
			}
			bindHelper(dummy);
			
			querystr ~= (bindings~" WHERE { ");
			foreach(f;filters) querystr ~= (f~". ");
			querystr ~= ("SERVICE wikibase:label { bd:serviceParam wikibase:language \""~dataLanguage~","~codingLang~"\". } } "~postfix);
			
			return rawQuery(querystr);
		}
		
		T[] getList(T=WdObject)(string dataLanguage="")
		{
			auto xml = getXml!T(dataLanguage);
			T[] resultlist;
			foreach(result;xml.elements)
			{
				auto item = new T;
				foreach(binding;result.elements)
				{
					static if(is(T:WdObject))
					{
						if(binding.bindingName=="item") item.id = binding.bindingValue.baseName;
					}
					auto targetMember = (binding.bindingName in binding2member);
					if(targetMember !is null)
					{
						setMember(item,*targetMember,binding.bindingValue);
					}
				}
				
				resultlist ~= item;
			}
			return resultlist;
		}
	}
	
	static Query find(string category, string name="", bool caseSensitive=true, bool allowContain=false)
	{
		auto q=new Query;
		if(category!="")
		{
			if(isNativeID(category))
			{
				q.filters ~= ("?item (wdt:P31/wdt:P279*) wd:"~category);
			}else{
				q.filters ~= ("VALUES (?categories) { "~name2IdList(category)~" }");
				q.filters ~= "?item (wdt:P31/wdt:P279*) ?categories";
			}
		}
		if(name!="")
		{
			q.nameFilter = name;
			q.nameFilterCase = caseSensitive;
			q.nameFilterExact = !allowContain;
		}
		return q;
	}
}

class WdObject
{
	string id;
	
	string get(string prop)
	{
		string bindTo = "val";
		prop = WikiData.propID(prop);
		auto xml = WikiData.rawQuery("SELECT ?"~bindTo~" WHERE { wd:"~id~" wdt:"~prop~" ?"~bindTo~". }");
		foreach(result;xml.elements) foreach(binding;result.elements) if(binding.bindingName==bindTo) return binding.bindingValue;
		return "";
	}
	
	WikiData.Query query(string prop, string propVar="prop")
	{
		prop = WikiData.propID(prop);
		auto q=new WikiData.Query;
		q.filters ~= ("wd:"~id~" p:"~prop~" ?"~propVar);
		q.analyzeVar = propVar;
		q.analyzeProp = prop;
		return q;
	}
}

class WdNamedObject : WdObject
{
	@WikiDataProp("?itemLabel") string name;
}

struct WikiDataProp
{
	string prop;
	string unit;
}
