#include "example-4dplugin.h"

void PluginMain(PA_long32 selector, PA_PluginParameters params) {
    
    switch(selector)
    {
        case 1 :
            example_greeting(params);
            break;

    }
}

static void example_greeting(PA_PluginParameters params) {

}
