module app;
import std;
import serverino;

mixin ServerinoMain;
import elemi;

// This endpoint will serve every request
void catchAll(Request request, Output output)
{
    output ~= buildHTML() ~ (html) {

        // Add the HTML doctype
        html ~ Element.HTMLDoctype;

        // Add the HTML element
        html.html ~ {

            // Add the head element inside the HTML element
            html.head ~ {
                html.title ~ request.path;
            };

            // Add the body element
            html.body ~ {

                // A placeholder image
                html.img.attr("src", "https://placehold.co/400x100?text=YOUR+LOGO&font=roboto") ~ null;

                // The title and some text
                html.h1 ~ i"Page: $(request.path)".text;
                html.p ~ i"Method: $(request.method)".text;
                html.p ~ i"Query Params: $(request.get)".text;
            };
        };
    };
}
