#pragma once
#include <QMainWindow>
#include <memory>
namespace Mucke {
class LibraryStore;
class CatalogService;
class MediaEngine;
class MainWindow : public QMainWindow {
    Q_OBJECT
public:
    MainWindow(LibraryStore*, CatalogService*, MediaEngine*, QWidget *parent = nullptr);
    ~MainWindow() override;
    void showMiniPlayer();
    void showVisualizer();
    void applyTheme(QString id);
    void captureScreenshots(QString directory);
private:
    class Impl;
    std::unique_ptr<Impl> d;
};
}
