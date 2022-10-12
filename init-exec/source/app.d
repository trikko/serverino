import std.stdio;
import serverino;

mixin ServerinoMain;

@endpoint
void page(Request request, Output output)
{
	output ~= request.dump(true);
}

@onServerInit
ServerinoConfig conf()
{
	return ServerinoConfig
		.create()
		.addListener("0.0.0.0", 8080)
		.setWorkers(4);
}