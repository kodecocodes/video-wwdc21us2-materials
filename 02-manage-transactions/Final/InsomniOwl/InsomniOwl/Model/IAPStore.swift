///// Copyright (c) 2021 Razeware LLC
/// 
/// Permission is hereby granted, free of charge, to any person obtaining a copy
/// of this software and associated documentation files (the "Software"), to deal
/// in the Software without restriction, including without limitation the rights
/// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
/// copies of the Software, and to permit persons to whom the Software is
/// furnished to do so, subject to the following conditions:
/// 
/// The above copyright notice and this permission notice shall be included in
/// all copies or substantial portions of the Software.
/// 
/// Notwithstanding the foregoing, you may not use, copy, modify, merge, publish,
/// distribute, sublicense, create a derivative work, and/or sell copies of the
/// Software in any work that is designed, intended, or marketed for pedagogical or
/// instructional purposes related to programming, coding, application development,
/// or information technology.  Permission for such use, copying, modification,
/// merger, publication, distribution, sublicensing, creation of derivative works,
/// or sale is expressly withheld.
/// 
/// This project and source code may use libraries or frameworks that are
/// released under various Open-Source licenses. Use of those libraries and
/// frameworks are governed by their own individual licenses.
///
/// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
/// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
/// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
/// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
/// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
/// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
/// THE SOFTWARE.

import Foundation
import StoreKit
import SwiftKeychainWrapper

class IAPStore: NSObject, ObservableObject {

  private let productIdentifiers: Set<String>
  public private(set) var purchasedProducts = Set<String>()
  @Published private(set) var products = [Product]()
  var taskHandler: Task.Handle<Void, Never>? = nil

  init(productsIDs: Set<String>) {
    productIdentifiers = productsIDs
    purchasedProducts = Set(productIdentifiers.filter { KeychainWrapper.standard.bool(forKey: $0) ?? false })
    super.init()
    taskHandler = listenForTransaction()
  }

  deinit {
    taskHandler?.cancel()
  }

  func listenForTransaction() -> Task.Handle<Void, Never> {
    return detach {
      for await result in Transaction.updates {
        var transaction: Transaction? = nil
        switch result {
        case .verified(let success):
          transaction =  success
        case .unverified(_):
          print("handle fail")
        }
        if let transaction = transaction {
          await self.addPurchase(purchaseIdentifier: transaction.productID)
          await transaction.finish()
        }
      }
      await self.requestProducts()
    }
  }

  @MainActor func requestProducts() async {
    do {
      products = try await Product.products(for: productIdentifiers)
      objectWillChange.send()
    } catch {
      print(error.localizedDescription)
    }
  }

  func buyProduct(product: Product) async -> Bool {
    var transaction: Transaction? = nil
    var verified = false
    do {
      let payment = try await product.purchase()
      switch payment {
      case .success(let verification):
        switch verification {
        case .verified(let successTransaction):
          transaction = successTransaction
          verified = true
        case .unverified(let failedTransaction):
          print(failedTransaction.jwsRepresentation)
          print(failedTransaction.headerData)
          print(failedTransaction.payloadData)
          print(failedTransaction.signedData)
        }
      case .userCancelled, .pending:
        return false
      default:
        return false
      }
    } catch {
      print(error.localizedDescription)
    }
    if verified {
      guard let transaction = transaction else {
        return false
      }
      if product.type == .consumable {
        await addConsumable(productIdentifier: product.id, amount: 3)
      } else {
        await addPurchase(purchaseIdentifier: product.id)
      }
      await transaction.finish()
      return true
    }
    return false
  }

  @MainActor func addPurchase(purchaseIdentifier: String) {
    if productIdentifiers.contains(purchaseIdentifier) {
      purchasedProducts.insert(purchaseIdentifier)
      KeychainWrapper.standard.set(true, forKey: purchaseIdentifier)
      objectWillChange.send()
    }
  }

  func isPurchased(_ productIdentifier: String) async -> Bool {
    if purchasedProducts.contains(productIdentifier) {
      return true
    }
    let result = await Transaction.latest(for: productIdentifier)
    switch result {
    case .verified(_):
      return true
    case .unverified(_):
      return false
    default:
      return false
    }
  }

  func restorePurchases() {
    SKPaymentQueue.default().restoreCompletedTransactions()
  }

  @MainActor func addConsumable(productIdentifier: String, amount: Int) {
    var currentTotal = consumableAmountFor(productIdentifier: productIdentifier)
    currentTotal += amount
    KeychainWrapper.standard.set(currentTotal, forKey: productIdentifier)
    objectWillChange.send()
  }

  func consumableAmountFor(productIdentifier: String) -> Int {
    KeychainWrapper.standard.integer(forKey: productIdentifier) ?? 0
  }

  @MainActor func decrementConsumable(productIdentifier: String) {
    var currentTotal = consumableAmountFor(productIdentifier: productIdentifier)
    if currentTotal > 0 {
      currentTotal -= 1
    }
    KeychainWrapper.standard.set(currentTotal, forKey: productIdentifier)
    objectWillChange.send()
  }
}

