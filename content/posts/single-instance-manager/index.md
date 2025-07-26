+++
title = "Preventing multiple instances of your Qt application"
description = "A simple way of ensuring only a single instance of your Qt application is running at the same time (on Linux)."
date = 2024-11-14T00:00:00+02:00
authors = ['Emma']
tags = ['Qt', 'C++', 'Linux']
draft = false
+++

## The problem

Recently, while I was working on a project of mine ([Ntfy Desktop](https://www.emmaexe.moe/projects/ntfydesktop/)) I ran across a problem. Ntfy Desktop is a client for ntfy, and its purpose is to receive notifications from the ntfy server and display them natively on the desktop.

The issue was: What happens when the user runs multiple instances of the app?
{{<br>}}
Each instance of the app would receive the same notification sent by the server separately and the user would see double notifications on the desktop, which isn't ideal.

The solution for this is to ensure only a single instance of your application can run at the same time.

---

## The options

Prior to Qt 5/6, the common solution for this was using QtSingleApplication which was a class extended from QApplication that was deprecated with Qt 4.

Nowadays there are a couple of ways to achieve this.

One option I considered for Ntfy Desktop was [itay-grudev's SingleApplication](https://github.com/itay-grudev/SingleApplication).

> [SingleApplication] is a replacement of the QtSingleApplication for Qt5 and Qt6.
> {{<br>}}
> Keeps the Primary Instance of your Application and kills each subsequent instances. It can (if enabled) spawn secondary (non-related to the primary) instances and can send data to the primary instance from secondary instances.

I discarded this option for two reasons.

First, at the time when I was searching for a solution to this problem, SingleApplication had a bug with Qt 6 and I couldn't get it to work. That seems to have been fixed since (though I haven't tested it).

Second, it relies on [QSharedMemory](https://doc.qt.io/qt-6/qsharedmemory.html) for communication between instances of your application, which [is discouraged](https://github.com/itay-grudev/SingleApplication/issues/170) by Qt developers and [is scheduled for deprecation in Qt 7](https://lists.qt-project.org/pipermail/development/2023-November/044680.html).

QSharedMemory is also problematic because it doesn't work by default in Flatpak and requires the addition of `--device=shm` to `finish-args` in your Flatpak manifest to grant the app to access `/dev/shm` for shared memory.

Another similar option, [QSystemSemaphore](https://doc.qt.io/qt-6/qsystemsemaphore.html), is in the same boat as QSharedMemory and is [being deprecated alongside it](https://lists.qt-project.org/pipermail/development/2023-November/044680.html).

Using [QLocalServer](https://doc.qt.io/qt-6/qlocalserver.html) and [QLocalSocket](https://doc.qt.io/qt-6/qlocalsocket.html) is a viable approach but they would require creating a socket file on the filesystem in a directory like `/tmp` and you would again run into permission issues with Flatpak.

---

## My solution

The approach I ended up using and will show here is [D-Bus](https://www.freedesktop.org/wiki/Software/dbus/) with Qt's wrapper, the [QDBusConnection](https://doc.qt.io/qt-6/qdbusconnection.html) class.

D-Bus will manage IPC for us, so multiple instances of our app can communicate together while being Flatpak-friendly as Flatpak does not restrict an app's access to its own D-Bus interface. It will also let us communicate more than just the boolean "*there is already an instance of this app running*" message, which is useful if your app is the handler of some protocol (via `x-scheme-handler`).

Let's start with a header:

```c++
#pragma once

#include <QObject>

class SingleInstanceManager: public QObject {
    Q_OBJECT
    public:
        SingleInstanceManager(QObject* parent = nullptr);
};
```

We create a new QObject that is going to handle all the D-Bus communication, I am calling mine `SingleInstanceManager`.

Our object is going to be the counterpart to a D-Bus interface. We define the interface we want to use with `Q_CLASSINFO`:

```c++
#pragma once

#include <QObject>

class SingleInstanceManager: public QObject {
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "com.example.application.SingleInstanceManager")
    public:
        SingleInstanceManager(QObject* parent = nullptr);
};
```

For compatability with Flatpak, we need to make sure that the interface belongs to the same namespace as the app's id (e.g. `com.example.application`).

Now that we have the skeleton of the header, let's create an implementation file:

```c++
#include "SingleInstanceManager.hpp"

#include <QDBusConnection>
#include <QDBusMessage>
#include <iostream>

SingleInstanceManager::SingleInstanceManager(QObject* parent): QObject(parent) {}
```

We need `QDBusConnection` and `QDBusMessage` for D-Bus and `iostream` for logging.

First, we create a `QDBusConnection` to the session bus:

```c++
#include "SingleInstanceManager.hpp"

#include <QDBusConnection>
#include <QDBusMessage>
#include <iostream>

SingleInstanceManager::SingleInstanceManager(QObject* parent): QObject(parent) {
    QDBusConnection sessionBus = QDBusConnection::sessionBus();
}
```

Next, we register our D-Bus service. We do this using `QDBusConnection::registerService`. If we fail to register our service, that indicates the presence of another instance that has already registered itself and is running.

```c++
#include "SingleInstanceManager.hpp"

#include <QDBusConnection>
#include <QDBusMessage>
#include <iostream>

SingleInstanceManager::SingleInstanceManager(QObject* parent): QObject(parent) {
    QDBusConnection sessionBus = QDBusConnection::sessionBus();
    
    if (!sessionBus.registerService("com.example.application")) {
        // Here, we will later send a message to the main instance of our app.
        exit(0);
    }
}
```

If we do manage to register ourselves on the session bus, we continue and register the `SingleInstanceManager` object as well.

```c++
#include "SingleInstanceManager.hpp"

#include <QDBusConnection>
#include <QDBusMessage>
#include <iostream>

SingleInstanceManager::SingleInstanceManager(QObject* parent): QObject(parent) {
    QDBusConnection sessionBus = QDBusConnection::sessionBus();
    
    if (!sessionBus.registerService("com.example.application")) {
        // Here, we will later send a message to the main instance of our app.
        exit(0);
    }

    if (!sessionBus.registerObject("/SingleInstanceManager", this, QDBusConnection::ExportAllSlots | QDBusConnection::ExportAllSignals)) {
        std::cerr << "Failed to register DBus object: " << sessionBus.lastError().message().toStdString() << std::endl;
        exit(1);
    }
}
```

We are registering the `SingleInstanceManager` (C++) object as a (D-Bus) object to our service and telling Qt to export all the slots and signals in our `SingleInstanceManager` to D-Bus, which we are going to use for communication between instances.

For this example, I will be using a string for the message that we will send over to the main instance of the application since it's what I need to send in Ntfy Desktop so that the app can handle protocol handling.

Going back to the header:

```c++
#pragma once

#include <QObject>
#include <QString>
#include <functional>
#include <optional>
#include <string>

class SingleInstanceManager: public QObject {
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "com.example.application.SingleInstanceManager")
    public:
        SingleInstanceManager(std::function<void(std::optional<std::string> data)> onNewInstanceStarted, std::optional<std::string> data, QObject* parent = nullptr);
        std::function<void(const std::optional<std::string> data)> onNewInstanceStarted;
    public slots:
        void newInstanceStarted(const QString& data);
};
```

To make this flexible, we are adding a void `std::function` with a `std::optional<std::string> data` parameter that our object will receive in its constructor and an `std::optional<std::string> data`.

The function will be triggered by the `newInstanceStarted` slot which itself will be triggered by D-Bus when another instance is started and fails to register itself with D-Bus. **When that happens, the failed instance will send the data string it received in its constructor to the main instance via D-Bus. The main instance will receive it via the newInstanceStarted slot, which is going to pass it to our onNewInstanceStarted `std::function`.**

You can change this if you want, but I prefer to work with standard c++ classes (i.e. `std::string` over `QString`) and also prefer to wrap them with a `std::optional` to be explicit that they may or may not contain data.

Let's implement this:

```c++
#include "SingleInstanceManager.hpp"

#include <QDBusConnection>
#include <QDBusMessage>
#include <iostream>

SingleInstanceManager::SingleInstanceManager(std::function<void(std::optional<std::string> data)> onNewInstanceStarted, std::optional<std::string> data, QObject* parent): QObject(parent), onNewInstanceStarted(onNewInstanceStarted) {
    QDBusConnection sessionBus = QDBusConnection::sessionBus();
    
    if (!sessionBus.registerService("com.example.application")) {
        // Here, we will later send a message to the main instance of our app.
        exit(0);
    }

    if (!sessionBus.registerObject("/SingleInstanceManager", this, QDBusConnection::ExportAllSlots | QDBusConnection::ExportAllSignals)) {
        std::cerr << "Failed to register DBus object: " << sessionBus.lastError().message().toStdString() << std::endl;
        exit(1);
    }
}

void SingleInstanceManager::newInstanceStarted(const QString& data) {
    if (this->onNewInstanceStarted) {
        this->onNewInstanceStarted( data.isEmpty() ? std::nullopt : std::make_optional(data.toStdString()) );
    }
}
```

We first fix our constructor's parameters and add our slot. In the slot, if the onNewInstanceStarted function exists, we call it and as a parameter give it either `std::nullopt` if the slot received no data or the value of the `QString` transformed into a `std::optional<std::string>`.

Next, we need to send the data if the instance we are running is not the main one:

```c++
#include "SingleInstanceManager.hpp"

#include <QDBusConnection>
#include <QDBusMessage>
#include <iostream>

SingleInstanceManager::SingleInstanceManager(std::function<void(std::optional<std::string> data)> onNewInstanceStarted, std::optional<std::string> data, QObject* parent): QObject(parent), onNewInstanceStarted(onNewInstanceStarted) {
    QDBusConnection sessionBus = QDBusConnection::sessionBus();
    
    if (!sessionBus.registerService("com.example.application")) {
        QDBusMessage message = QDBusMessage::createMethodCall("com.example.application", "/SingleInstanceManager", "com.example.application.SingleInstanceManager", "newInstanceStarted");
        if (data.has_value()) {
            message << QString(data.value().c_str());
        } else {
            message << "";
        }
        exit(0);
    }

    if (!sessionBus.registerObject("/SingleInstanceManager", this, QDBusConnection::ExportAllSlots | QDBusConnection::ExportAllSignals)) {
        std::cerr << "Failed to register DBus object: " << sessionBus.lastError().message().toStdString() << std::endl;
        exit(1);
    }
}

void SingleInstanceManager::newInstanceStarted(const QString& data) {
    if (this->onNewInstanceStarted) {
        this->onNewInstanceStarted( data.isEmpty() ? std::nullopt : std::make_optional(data.toStdString()) );
    }
}
```

Here we are creating a QDBusMessage that we are going to send. This is the signature of the function: `QDBusMessage::createMethodCall(const QString &service, const QString &path, const QString &interface, const QString &method)`. The service is the name of [our service](#hl-8-10) that we tried to register and failed (because the main instance already exists and registered it). The path is the path of [our D-Bus object](#hl-8-20) (in our case `/SingleInstanceManager`). The interface is the name of [our interface](#hl-6-11) that we defined in the header with Q_CLASSINFO. And the method is the slot that we exported that we are calling, `newInstanceStarted`.

After we create our message, we pipe into it either an empty string or the value of the data string, depending on whether it holds some value or not.

Now we are ready to send our message:

```c++
#include "SingleInstanceManager.hpp"

#include <QDBusConnection>
#include <QDBusMessage>
#include <iostream>

SingleInstanceManager::SingleInstanceManager(std::function<void(std::optional<std::string> data)> onNewInstanceStarted, std::optional<std::string> data, QObject* parent): QObject(parent), onNewInstanceStarted(onNewInstanceStarted) {
    QDBusConnection sessionBus = QDBusConnection::sessionBus();
    
    if (!sessionBus.registerService("com.example.application")) {
        QDBusMessage message = QDBusMessage::createMethodCall("com.example.application", "/SingleInstanceManager", "com.example.application.SingleInstanceManager", "newInstanceStarted");
        if (data.has_value()) {
            message << QString(data.value().c_str());
        } else {
            message << "";
        }

        QDBusMessage reply = sessionBus.call(message);
        if (reply.type() == QDBusMessage::ErrorMessage) {
            std::cerr << "DBus error: " << reply.errorMessage().toStdString() << std::endl;
        }

        exit(0);
    }

    if (!sessionBus.registerObject("/SingleInstanceManager", this, QDBusConnection::ExportAllSlots | QDBusConnection::ExportAllSignals)) {
        std::cerr << "Failed to register DBus object: " << sessionBus.lastError().message().toStdString() << std::endl;
        exit(1);
    }
}

void SingleInstanceManager::newInstanceStarted(const QString& data) {
    if (this->onNewInstanceStarted) {
        this->onNewInstanceStarted( data.isEmpty() ? std::nullopt : std::make_optional(data.toStdString()) );
    }
}
```

We send the message and read the reply. If it is an error we log the error and exit out of the program.

And that's it. We now have a working `SingleInstanceManager` that will send a string message to the main instance and close itself if it is a secondary instance.

---

## Demo

We can write a small test program for this:

```c++
#include "SingleInstanceManager/SingleInstanceManager.hpp"

#include <QApplication>
#include <iostream>
#include <optional>
#include <string>

int main(int argc, char* argv[]) {
    QApplication app(argc, argv);

    std::optional<std::string> parameters = std::nullopt;
    for (int i = 1; i < argc; i++) {
        if (!parameters.has_value()) { parameters = std::make_optional<std::string>(""); }
        parameters.value().append(argv[i]).append(" ");
    }

    SingleInstanceManager singleInstanceManager(
        [&](std::optional<std::string> data) {
            /*
                We can do something interesting here with our data since we have access to our main function's scope.
                Since this function is a public member of the class we can also just replace it with something else later on.
                For this example, we just print the data to stdout.
            */ 
            std::cout << (data.has_value() ? data.value() : "A new instance was started but no parameters were passed.") << std::endl;
        },
        parameters
    );

    return app.exec();
}
```

We are creating our QApplication, looping over all parameters and adding them into the `parameters` variable, and then creating our `SingleInstanceManager`. In the function for this example, we simply print the received data or the example string if no data was sent. We also give it our parameters that we read from `argc` and `argv`.

Here it is in action:

{{< video demo.mp4 >}}

---

I am releasing all the code in this post under MIT-0, so feel free to use it however you like.

{{< button href="https://github.com/emmaexe/SingleInstanceManager" icon="fa-brands fa-github" icontype="fa" class="filled" >}}
GitHub repo
{{< /button >}}
